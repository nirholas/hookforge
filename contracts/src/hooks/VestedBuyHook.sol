// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";

import {ForgeMetadata} from "../base/ForgeMetadata.sol";
import {ForgePayout} from "../base/ForgePayout.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title VestedBuyHook
 * @notice Vests what a buyer receives, at the pool, so a launch can sell without handing every buyer a same-block
 * exit.
 *
 * @dev A token that wants its early buyers to hold has two options today and both are bad. Vesting in the token
 * contract binds everyone forever, including the market makers and the exchanges the project needs, and it is the
 * reason so many tokens ship with transfer restrictions nobody can later remove. Or the project vests nothing and
 * watches the first hour decide the price, because a buyer who can sell immediately is not a holder, they are a
 * position with a very short horizon.
 *
 * The thing that actually wants vesting is not the token, it is the purchase. Buying through this pool during its
 * vesting period delivers a share of the tokens now and the rest on a schedule, and the token itself is untouched:
 * no transfer hooks, no allowlist, no permanent restriction, and every other venue trades it normally. A project can
 * point its launch at this pool, get holders rather than flippers out of it, and still have a plain ERC-20.
 *
 * The buyer keeps `immediateBps` of the fill and the hook holds the rest as ERC-6909 claims, releasing them linearly
 * from `cliff` to `cliff + duration`. Claims are paid as real tokens.
 *
 * Attribution needs no signature. `hookData` may name who the vested tokens belong to, and naming somebody else
 * gives them your tokens, which is the only thing a forged attribution achieves. A buy that names nobody vests to
 * the router it came through, which lets a launchpad run the vesting for its users.
 *
 * Exact-output buys are refused while vesting is live, and that is a security property rather than a limitation.
 * Uniswap v4 lets a hook adjust only the swap's unspecified currency, which on an exact-output buy is the input, not
 * the output. A hook that quietly declined to vest those would be a hook whose vesting is bypassed by changing one
 * field, so it says no instead.
 *
 * @custom:slug vested-buy
 * @custom:family Time
 * @custom:prior-art Vesting is normally a property of the token (transfer restrictions, locked allocations) or of a
 * distribution contract that holds an allocation and releases it. Vesting the purchase at the venue, so the token
 * stays a plain ERC-20 and only buys through this pool are vested, is the contribution here.
 * @custom:limitation It binds one pool. The same token bought anywhere else is not vested, so this shapes a launch
 * rather than enforcing a lockup, and a project that needs the second should vest in the token. The schedule also
 * cannot be cancelled or clawed back by anybody, including the project, which is deliberate but means a buyer who
 * loses their key loses the unvested remainder.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract VestedBuyHook is BaseHook, ForgeMetadata, ForgePayout, PoolConfigurable {
    using CurrencySettler for Currency;
    using SafeCast for *;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Which swap direction buys the vesting token.
        bool buyIsZeroForOne;
        /// @notice Share of each buy delivered immediately, in basis points.
        uint16 immediateBps;
        /// @notice Seconds after the buy before anything unlocks.
        uint32 cliff;
        /// @notice Seconds over which the remainder unlocks, after the cliff.
        uint32 duration;
        /// @notice When vesting stops applying and the pool becomes ordinary.
        uint64 endsAt;
    }

    /// @notice One buyer's vesting position for a pool.
    struct Grant {
        /// @notice Total vested to this account, in the bought currency.
        uint128 total;
        /// @notice How much of it has been claimed.
        uint128 claimed;
        /// @notice When the most recent buy landed, which the schedule runs from.
        uint64 startedAt;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice Each account's grant, per pool.
    mapping(PoolId => mapping(address => Grant)) public grantOf;

    /// @dev `immediateBps` above 100% would deliver more than the buy produced.
    error InvalidShare();

    /// @dev A vesting period that has already ended cannot be configured.
    error EndsInThePast();

    /// @dev Exact-output buys cannot be vested, so they are refused while vesting is live. See the contract notes.
    error ExactOutputBuysRefused();

    /// @dev There is nothing unlocked to claim.
    error NothingVested();

    /// @notice Emitted once per pool, when its schedule is fixed.
    event PoolConfigured(PoolId indexed id, uint16 immediateBps, uint32 cliff, uint32 duration, uint64 endsAt);

    /// @notice Emitted on every vested buy.
    event Vested(PoolId indexed id, address indexed account, uint256 amount, uint256 total);

    /// @notice Emitted when a buyer takes what has unlocked.
    event Claimed(PoolId indexed id, address indexed account, uint256 amount);

    /// @dev The pool key each configured pool was created with, kept so claims know which currency to pay in.
    mapping(PoolId => PoolKey) private _keyOf;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Fix the schedule for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.immediateBps > BPS) revert InvalidShare();
        // Vesting windows are set in days or weeks; proposer drift cannot reach them.
        // forge-lint: disable-next-line(block-timestamp)
        if (cfg.endsAt <= block.timestamp) revert EndsInThePast();

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        _keyOf[id] = key;
        emit PoolConfigured(id, cfg.immediateBps, cfg.cliff, cfg.duration, cfg.endsAt);
    }

    /// @notice Whether the pool is still vesting buys.
    function vestingActive(PoolId id) public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < configOf[id].endsAt;
    }

    /// @notice How much of `account`'s grant has unlocked in total, claimed or not.
    function unlocked(PoolId id, address account) public view returns (uint256) {
        Grant memory grant = grantOf[id][account];
        if (grant.total == 0) return 0;

        Config memory cfg = configOf[id];
        uint256 start = uint256(grant.startedAt) + cfg.cliff;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < start) return 0;
        if (cfg.duration == 0) return grant.total;

        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= cfg.duration) return grant.total;
        return (uint256(grant.total) * elapsed) / cfg.duration;
    }

    /// @notice What `account` may take right now.
    function claimable(PoolId id, address account) public view returns (uint256) {
        Grant memory grant = grantOf[id][account];
        uint256 available = unlocked(id, account);
        return available > grant.claimed ? available - grant.claimed : 0;
    }

    /// @notice Take everything that has unlocked, as real tokens.
    function claim(PoolKey calldata key, address to) external returns (uint256 amount) {
        PoolId id = key.toId();
        amount = claimable(id, msg.sender);
        if (amount == 0) revert NothingVested();

        // Casting to 'uint128' is safe because `amount` is bounded by the grant total, itself a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        grantOf[id][msg.sender].claimed += uint128(amount);
        emit Claimed(id, msg.sender, amount);

        Config memory cfg = configOf[id];
        // The bought currency is the one the buyer receives, which is the opposite of the one they pay.
        (uint256 amount0, uint256 amount1) = cfg.buyIsZeroForOne ? (uint256(0), amount) : (amount, uint256(0));
        _payout(key.currency0, key.currency1, to, amount0, amount1);
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].endsAt == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Holds back the vesting share of a buy.
     *
     * The withheld amount is taken as an ERC-6909 claim on the `PoolManager` and returned as a positive hook delta,
     * which is how v4 expresses "the swapper receives this much less".
     */
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];

        if (params.zeroForOne != cfg.buyIsZeroForOne || !vestingActive(id)) return (this.afterSwap.selector, 0);
        // An exact-output buy adjusts the input, not the output, so vesting it is not expressible. Refusing is the
        // only honest option: silently letting it through would make the vesting optional.
        if (params.amountSpecified > 0) revert ExactOutputBuysRefused();

        int128 received = cfg.buyIsZeroForOne ? delta.amount1() : delta.amount0();
        if (received <= 0) return (this.afterSwap.selector, 0);

        // Casting to 'uint128' is safe because the guard above establishes `received > 0`.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 output = uint256(uint128(received));
        uint256 withheld = (output * (BPS - cfg.immediateBps)) / BPS;
        if (withheld == 0) return (this.afterSwap.selector, 0);

        Currency bought = cfg.buyIsZeroForOne ? key.currency1 : key.currency0;
        bought.take(poolManager, address(this), withheld, true);

        // A buy may name who the vesting belongs to. No signature: naming somebody else gives them your tokens.
        address account = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;

        Grant storage grant = grantOf[id][account];
        // Casting to 'uint128' is safe because `withheld` is a share of an output that arrived as an int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        grant.total += uint128(withheld);
        // The schedule restarts from the latest buy, so topping up does not backdate the new tokens.
        // forge-lint: disable-next-line(block-timestamp)
        grant.startedAt = uint64(block.timestamp);

        emit Vested(id, account, withheld, grant.total);
        return (this.afterSwap.selector, withheld.toInt128());
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    /// @inheritdoc ForgePayout
    function _payoutManager() internal view override returns (IPoolManager) {
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
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "VestedBuy";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "vested-buy.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "launch";
        tags[1] = "vesting";
        tags[2] = "anti-flip";
        tags[3] = "time";
        tags[4] = "no-admin";
    }
}
