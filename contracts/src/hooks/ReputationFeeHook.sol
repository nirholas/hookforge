// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {IAgentReputation} from "../interfaces/IAgentReputation.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title ReputationFeeHook
 * @notice Charges a counterparty according to how it has behaved, using an on-chain reputation registry, with no
 * signature to present and nothing for a router to forward.
 *
 * @dev Pools price everyone identically because they cannot tell anyone apart, and the cost of that falls on the
 * people who are cheapest to trade with. A venue that could distinguish its flow would quote the retail order and the
 * arbitrageur differently, which is what every venue that can identify its counterparties actually does.
 *
 * The obstacle in v4 is that a hook does not see the trader. `beforeSwap` receives the router, not the person who
 * called it, so any scheme keyed on the trader's address needs the trader to sign something and the router to forward
 * it, which means most routers cannot trade the pool at all.
 *
 * This takes the other route. An agent registers the router it trades through, once, in a transaction sent from its
 * own address:
 *
 *   reputationFee.register(myRouter);
 *
 * Thereafter the hook resolves `sender` to that agent with one storage read, asks the registry for its score, and
 * prices the swap between `maxFee` at a score of zero and `minFee` at a perfect score. No signature, no `hookData`,
 * nothing for a router to support. Flow through an unregistered router is simply unknown and pays `maxFee`, which is
 * the correct default: an unidentified counterparty is priced as the worst one.
 *
 * Spoofing is not possible because the mapping runs from router to agent and only the agent can write its own entry.
 * Registering a router somebody else also uses means paying for their flow with your reputation, which is a mistake
 * you can only make about yourself.
 *
 * The registry is fixed at deployment and the fee bounds are fixed before the pool exists. There is no admin and no
 * way to re-point the pool at a friendlier scorer once liquidity has arrived.
 *
 * @custom:slug reputation-fee
 * @custom:family Agent-native
 * @custom:prior-art Identity-gated hooks are common (KYC, Civic, VioletID, World ID, PureFi) and they gate: pass or be refused. Loyalty and fidelity hooks discount by volume or tenure, which is a proxy for behaviour rather than a judgement of it. Pricing continuously off an external reputation score, and resolving the trader through a registered router so no signature or hookData is needed, is the contribution here.
 * @custom:limitation The pool trusts the registry absolutely: a registry that can be bought is a fee schedule that can be bought, and nothing here detects that. Registration is also per router, so an agent that trades through a router it has not registered pays the unknown rate until it registers, and an agent using a shared public router either cannot register it or is subsidising everyone else who uses it.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract ReputationFeeHook is ForgeFeeHook, PoolConfigurable {
    /// @notice The registry this pool prices against. Fixed at deployment.
    IAgentReputation public immutable registry;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Fee charged to a perfect score, in hundredths of a bip.
        uint24 minFee;
        /// @notice Fee charged to a score of zero, and to anyone the pool cannot identify.
        uint24 maxFee;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The agent behind each registered router.
    mapping(address => address) public agentOf;

    /// @dev `maxFee` must be at least `minFee`; a schedule that rewards a bad score is a configuration error.
    error MaxBelowMin();

    /// @dev A registry that reports a zero scale cannot be normalised against.
    error InvalidRegistry();

    /// @notice Emitted once per pool, when its fee bounds are fixed.
    event PoolConfigured(PoolId indexed id, uint24 minFee, uint24 maxFee);

    /// @notice Emitted when an agent claims a router as its own.
    event RouterRegistered(address indexed router, address indexed agent);

    /// @notice Emitted on every swap with the score that was found and the fee it produced.
    event ReputationPriced(PoolId indexed id, address indexed agent, uint256 score, uint24 fee);

    constructor(IPoolManager _poolManager, IAgentReputation _registry) ForgeFeeHook(_poolManager) {
        if (_registry.scoreScale() == 0) revert InvalidRegistry();
        registry = _registry;
    }

    /**
     * @notice Claim `router` as the caller's, so swaps arriving through it are priced against the caller's score.
     * @dev Callable repeatedly and by anyone, for any router, because claiming a router only ever attaches the
     * caller's own reputation to flow arriving through it. The worst somebody can do by claiming a router they do not
     * control is pay for other people's swaps with their own good name.
     */
    function register(address router) external {
        agentOf[router] = msg.sender;
        emit RouterRegistered(router, msg.sender);
    }

    /// @notice Stop pricing flow through `router` against the caller.
    function deregister(address router) external {
        if (agentOf[router] == msg.sender) {
            agentOf[router] = address(0);
            emit RouterRegistered(router, address(0));
        }
    }

    /// @notice Fix the fee bounds for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.maxFee < cfg.minFee) revert MaxBelowMin();
        FeeMath.requireValid(cfg.maxFee);

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.minFee, cfg.maxFee);
    }

    /**
     * @notice The fee a swap arriving through `router` would pay.
     * @dev Interpolates linearly from `maxFee` at a score of zero to `minFee` at the registry's full scale. An
     * unregistered router, or an agent the registry does not know, pays `maxFee`.
     */
    function feeFor(PoolId id, address router) public view returns (uint24 fee, address agent, uint256 score) {
        Config memory cfg = configOf[id];
        agent = agentOf[router];
        if (agent == address(0)) return (cfg.maxFee, address(0), 0);

        score = registry.scoreOf(agent);
        uint256 scale = registry.scoreScale();
        if (score >= scale) return (cfg.minFee, agent, score);

        uint256 discount = FeeMath.mulDiv(uint256(cfg.maxFee) - cfg.minFee, score, scale);
        // Casting to 'uint24' is safe because `discount` is bounded by `maxFee - minFee`, so the result lies
        // between `minFee` and `maxFee`, both uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint24(uint256(cfg.maxFee) - discount), agent, score);
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].maxFee == 0) revert PoolNotConfigured();
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /// @dev Prices the swap off the reputation behind the router it arrived through.
    function _getFee(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (uint24 fee, address agent, uint256 score) = feeFor(id, sender);
        emit ReputationPriced(id, agent, score, fee);
        return fee;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "ReputationFee";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "reputation-fee.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "agent";
        tags[1] = "reputation";
        tags[2] = "dynamic-fee";
        tags[3] = "erc8004";
        tags[4] = "no-admin";
    }
}
