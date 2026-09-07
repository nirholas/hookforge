// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title DrawdownCapHook
 * @notice A limit down. The pool may not fall more than a fixed distance below where the current epoch opened, and
 * the limit resets on a schedule rather than on anyone's say-so.
 *
 * @dev {CircuitBreakerHook} is symmetric and reactive: a violent move in either direction halts the pool, then the
 * halt clears. This is the other shape, and it is the one commodity and equity venues actually use. It is asymmetric,
 * because a collapse and a rally are not the same event for the people holding the asset. It is a hard cap rather
 * than a trigger, so the fall never happens rather than being noticed after it did. And it resets on a clock, so
 * everyone can see in advance when selling reopens and at what level.
 *
 *   allowed while  openTick - tick <= maxFallTicks,  where openTick is the tick at the start of the epoch
 *
 * Buying is never restricted. A pool at its limit can still be bid up, and doing so does not raise the limit for that
 * epoch, because the reference is the epoch's opening price and not a running high. When the epoch rolls, the pool
 * takes its current price as the new opening and gets a fresh allowance.
 *
 * As with {RatchetFloorHook}, the cap is expressed as a price a router can trade into: {sqrtPriceLimitDownX96}
 * returns the value to pass as a swap's `sqrtPriceLimitX96`, so a seller fills as far as the cap allows and stops
 * there. The `afterSwap` revert is the backstop for callers that pass no limit.
 *
 * Liquidity operations are never blocked, so nobody is trapped by a limit-down epoch.
 *
 * One tick is one basis point to within rounding, so `maxFallTicks = 1000` is a ten percent daily limit.
 *
 * @custom:slug drawdown-cap
 * @custom:family Risk
 * @custom:prior-art Trading halts and price bands are standard on regulated venues and absent on-chain, where the
 * closest equivalents are governance pause switches and oracle-deviation guards. Hook implementations of trading
 * hours exist. A scheduled, asymmetric, self-resetting limit down with no privileged role does not.
 * @custom:limitation A limit down does not stop a decline, it defers one. If the market has genuinely repriced, the
 * pool reopens each epoch and falls again, one limit at a time, and in the meantime the gap between the pool and the
 * real price is an arbitrage that grows. It buys holders time to react, which is worth something, and it costs
 * liquidity providers the trades they would rather have made, which is not free.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract DrawdownCapHook is ForgeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice How far below the epoch's opening tick the pool may fall. Must be non-zero.
        uint24 maxFallTicks;
        /// @notice Length of an epoch in seconds. Must be non-zero.
        uint32 epochSeconds;
    }

    /// @notice The reference the current epoch is measured against.
    struct Epoch {
        int24 openTick;
        uint64 openedAt;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The current epoch, per pool.
    mapping(PoolId => Epoch) public epochOf;

    /// @dev `maxFallTicks` or `epochSeconds` was zero.
    error InvalidConfig();

    /// @dev The swap would take the pool past this epoch's limit down. Pass `sqrtPriceLimitDownX96` as a price limit.
    error LimitDown(int24 tick, int24 limitTick);

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 maxFallTicks, uint32 epochSeconds);

    /// @notice Emitted when an epoch rolls and the pool takes a new reference price.
    event EpochOpened(PoolId indexed id, int24 openTick, int24 limitTick);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.maxFallTicks == 0 || cfg.epochSeconds == 0) revert InvalidConfig();

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.maxFallTicks, cfg.epochSeconds);
    }

    /// @notice The lowest tick this epoch permits.
    function limitTick(PoolId id) public view returns (int24) {
        return _limitTick(epochOf[id].openTick, configOf[id].maxFallTicks);
    }

    /// @notice The price limit a seller should carry to fill into the cap instead of reverting at it.
    function sqrtPriceLimitDownX96(PoolId id) public view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(limitTick(id));
    }

    /// @notice How many ticks of fall this epoch has left, and when the allowance resets.
    function headroom(PoolId id) public view returns (uint256 ticksRemaining, uint256 resetsAt) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        int24 limit = limitTick(id);
        // casting to 'uint256' is safe because the ternary only reaches it when `tick > limit`, so the difference
        // is strictly positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        ticksRemaining = tick > limit ? uint256(int256(tick - limit)) : 0;
        resetsAt = uint256(epochOf[id].openedAt) + configOf[id].epochSeconds;
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
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Requires a configuration, and opens the first epoch at the pool's opening price.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        if (cfg.maxFallTicks == 0) revert PoolNotConfigured();

        epochOf[id] = Epoch(tick, uint64(block.timestamp));
        emit EpochOpened(id, tick, _limitTick(tick, cfg.maxFallTicks));
        return this.afterInitialize.selector;
    }

    /// @dev Rolls the epoch when its clock has run out, so the allowance resets on schedule and not on demand.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Epoch memory epoch = epochOf[id];

        // Safe against timestamp drift: an epoch is measured in minutes at least, so the seconds a proposer can shift
        // `block.timestamp` by cannot open one meaningfully early.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - epoch.openedAt >= configOf[id].epochSeconds) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            epochOf[id] = Epoch(tick, uint64(block.timestamp));
            emit EpochOpened(id, tick, _limitTick(tick, configOf[id].maxFallTicks));
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Refuses to leave the pool below this epoch's limit.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tick,,) = poolManager.getSlot0(id);

        int24 limit = _limitTick(epochOf[id].openTick, configOf[id].maxFallTicks);
        if (tick < limit) revert LimitDown(tick, limit);

        return (this.afterSwap.selector, 0);
    }

    /// @dev `openTick - maxFallTicks`, clamped into the range Uniswap accepts.
    function _limitTick(int24 openTick, uint24 maxFallTicks) private pure returns (int24) {
        int256 limit = int256(openTick) - int256(uint256(maxFallTicks));
        if (limit < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        // casting to 'int24' is safe because `openTick` is already a valid tick and `maxFallTicks` only lowers it,
        // so the result is at most MAX_TICK and the branch above catches everything below MIN_TICK.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(limit);
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "DrawdownCap";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "drawdown-cap.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "risk";
        tags[1] = "circuit-breaker";
        tags[2] = "oracle-free";
        tags[3] = "no-admin";
    }
}
