// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title CommitRevealDarkHook
 * @notice Every swap must have been committed to in an earlier block, so nobody can react to an order they can see.
 *
 * @dev Sandwiching works because of a timing asymmetry, not because of secrecy. Your order is visible before it
 * executes, and an attacker can construct and place their own transactions after seeing it. Every defence that hides
 * the order attacks the wrong half of that: encrypted mempools, private relays and threshold schemes all try to stop
 * the attacker seeing, which is hard, needs new infrastructure, and fails the moment one relay defects.
 *
 * This attacks the other half. If the pool accepts only swaps that were committed to at least one block earlier, then
 * an attacker who sees your order cannot act on it in the pool, because their own reaction would need a commitment
 * made before they knew there was anything to react to. Seeing the order stops being useful. Nothing has to be
 * hidden, and nothing has to be trusted.
 *
 * A commitment is a hash of the swap's parameters and a salt, so it reveals nothing until it is used. Revealing means
 * simply making the swap: the hook recomputes the hash from what actually arrived and requires it to match a
 * commitment that is old enough, unused and unexpired. A commitment that does not match is not a swap this pool will
 * accept.
 *
 * Commitments carry a bond, and this is the part that makes the scheme cost something to abuse. Without it, a trader
 * would commit to every order they might want at every size, then reveal the one they liked, which is a free option
 * on the pool paid for by nobody. The bond is returned in full when the commitment is used and forfeited to the pool
 * when it expires unused, so keeping options open is exactly as expensive as the options are worth to you.
 *
 * The cost of all this is two transactions and a delay of at least one block, and that is the honest trade. A pool
 * wearing this hook is not for the impatient; it is for flow large enough that being sandwiched costs more than
 * waiting a block.
 *
 * @custom:slug commit-reveal-dark
 * @custom:family Order flow and MEV
 * @custom:prior-art Commit-reveal is old, and appears on-chain in ENS registration, in sealed-bid auctions and in the sandwich-resistant AMM designs that reorder within a block. Encrypted mempools (Shutter, SUAVE, threshold schemes) attack the same problem by hiding the order. Requiring every swap in a pool to have been committed in an earlier block, so that seeing an order is useless rather than impossible, is the contribution here.
 * @custom:limitation Two transactions and a block of delay on every trade, which rules the pool out for anything latency-sensitive and makes it unusable through routers that will not forward the salt. It does not stop an attacker who commits speculatively every block and reveals when they see something worth reacting to: the bond makes that expensive rather than impossible, and a pool that sets the bond too low is not protected, it is inconvenient. Finally, a reveal carries its salt in the clear, so an observer can copy it and execute your trade ahead of you. That is a denial rather than a theft, since the copier pays for the swap and the bond still returns to whoever committed, but a trader who is being griefed this way has no recourse beyond committing again.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract CommitRevealDarkHook is ForgeHook, PoolConfigurable {
    /// @notice A standing commitment.
    struct Commitment {
        /// @notice Who made it. Only they can reveal it.
        address owner;
        /// @notice The block it was made in, which the delay is measured from.
        uint64 madeAt;
        /// @notice The bond held against it.
        uint128 bond;
    }

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Blocks that must pass between committing and revealing. At least one.
        uint32 delayBlocks;
        /// @notice Blocks after which an unused commitment expires and its bond is forfeited.
        uint32 ttlBlocks;
        /// @notice The bond a commitment must carry.
        uint128 bond;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice Standing commitments, by their hash.
    mapping(bytes32 => Commitment) public commitmentOf;

    /// @notice Bonds forfeited to each pool by commitments that expired unused.
    mapping(PoolId => uint256) public forfeited;

    /// @dev A delay of zero would let somebody commit and reveal in the same block, which is no protection at all.
    error InvalidDelay();

    /// @dev The time to live must exceed the delay, or a commitment expires before it may be used.
    error InvalidTtl();

    /// @dev The bond sent does not match what the pool requires.
    error WrongBond(uint256 required);

    /// @dev This commitment already exists. Vary the salt.
    error AlreadyCommitted();

    /// @dev The swap does not match any standing commitment.
    error NotCommitted(bytes32 expected);

    /// @dev The commitment is not old enough to be revealed yet.
    error TooSoon(uint256 revealableAt);

    /// @dev The commitment has expired and its bond is forfeited.
    error Expired(uint256 expiredAt);

    /// @dev The commitment has not expired, so its bond cannot be swept.
    error NotExpiredYet(uint256 expiresAt);

    /// @dev There is nothing to withdraw.
    error NothingToWithdraw();

    /// @notice Emitted when a commitment is made. The hash reveals nothing about the order.
    event Committed(PoolId indexed id, bytes32 indexed commitment, address indexed owner, uint256 revealableAt);

    /// @notice Emitted when a commitment is used by the swap it described. The owner is who gets the bond back.
    event Revealed(PoolId indexed id, bytes32 indexed commitment, address indexed owner);

    /// @notice Emitted when an expired commitment's bond is forfeited to the pool.
    event Forfeited(PoolId indexed id, bytes32 indexed commitment, uint256 bond);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the terms for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.delayBlocks == 0) revert InvalidDelay();
        if (cfg.ttlBlocks <= cfg.delayBlocks) revert InvalidTtl();

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
    }

    /**
     * @notice The hash a trader commits to.
     *
     * @dev Covers the pool and every parameter of the swap, so a commitment is good for exactly one order on exactly
     * one pool. It deliberately does not cover the trader's address: a swap arrives at the hook from whichever router
     * carried it, never from the trader, so an address in the hash would make every commitment unrevealable through
     * the routing infrastructure anybody actually uses. The salt is what ties the commitment to its author. It is also
     * what makes the commitment reveal nothing, since without it an observer could enumerate plausible sizes and
     * match the hash.
     */
    function commitmentHash(
        PoolId id,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(id, zeroForOne, amountSpecified, sqrtPriceLimitX96, salt));
    }

    /// @notice Make a commitment. The bond comes back when it is used, and is forfeited if it expires unused.
    function commit(PoolKey calldata key, bytes32 commitment) external payable {
        PoolId id = key.toId();
        Config memory cfg = configOf[id];
        if (msg.value != cfg.bond) revert WrongBond(cfg.bond);
        if (commitmentOf[commitment].owner != address(0)) revert AlreadyCommitted();

        commitmentOf[commitment] =
            Commitment({owner: msg.sender, madeAt: uint64(block.number), bond: uint128(msg.value)});

        emit Committed(id, commitment, msg.sender, block.number + cfg.delayBlocks);
    }

    /**
     * @notice Forfeit an expired commitment's bond to the pool.
     * @dev Callable by anyone. The bond does not go to the caller, so there is no incentive to race, only to tidy;
     * the pool keeps it, which is who the abandoned option was written against.
     */
    function sweepExpired(PoolKey calldata key, bytes32 commitment) external {
        PoolId id = key.toId();
        Commitment memory standing = commitmentOf[commitment];
        if (standing.owner == address(0)) revert NotCommitted(commitment);

        uint256 expiresAt = uint256(standing.madeAt) + configOf[id].ttlBlocks;
        if (block.number <= expiresAt) revert NotExpiredYet(expiresAt);

        delete commitmentOf[commitment];
        forfeited[id] += standing.bond;
        emit Forfeited(id, commitment, standing.bond);
    }

    /// @notice Send a pool's forfeited bonds wherever its providers want them. Callable by anyone.
    function distributeForfeited(PoolKey calldata key, address to) external {
        PoolId id = key.toId();
        uint256 amount = forfeited[id];
        if (amount == 0) revert NothingToWithdraw();
        forfeited[id] = 0;

        (bool sent,) = to.call{value: amount}("");
        require(sent, "distribution failed");
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].delayBlocks == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Requires the swap to match a standing commitment, and returns the bond.
     *
     * The hash is recomputed from what actually arrived rather than from anything the caller asserts, so a swap that
     * differs from its commitment in any parameter simply does not match one.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];

        bytes32 salt = hookData.length == 32 ? abi.decode(hookData, (bytes32)) : bytes32(0);
        bytes32 commitment =
            commitmentHash(id, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96, salt);

        Commitment memory standing = commitmentOf[commitment];
        if (standing.owner == address(0)) revert NotCommitted(commitment);

        uint256 revealableAt = uint256(standing.madeAt) + cfg.delayBlocks;
        if (block.number < revealableAt) revert TooSoon(revealableAt);

        uint256 expiresAt = uint256(standing.madeAt) + cfg.ttlBlocks;
        if (block.number > expiresAt) revert Expired(expiresAt);

        delete commitmentOf[commitment];
        emit Revealed(id, commitment, standing.owner);

        if (standing.bond > 0) {
            (bool sent,) = standing.owner.call{value: standing.bond}("");
            require(sent, "bond refund failed");
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "CommitRevealDark";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "commit-reveal-dark.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "mev";
        tags[1] = "anti-sandwich";
        tags[2] = "commit-reveal";
        tags[3] = "order-flow";
        tags[4] = "no-admin";
    }
}
