// SPDX-License-Identifier: Apache-2.0
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
 * @title RatchetFloorHook
 * @notice A price floor that only ever moves up.
 *
 * @dev A token's floor price is normally a promise: a treasury that says it will bid, a team that says it will buy
 * back. Promises are only as good as the balance behind them and the people holding the keys. This hook makes the
 * floor a property of the pool instead. It records the highest tick the pool has ever reached and refuses to let the
 * price settle more than `offsetTicks` below it:
 *
 *   floor = max(floor, highWaterTick - offsetTicks)
 *
 * The floor is monotone by construction. It has no setter, no owner and no emergency path, so it cannot be lowered by
 * anyone, including whoever deployed the pool. A rally raises it permanently; a decline never moves it.
 *
 * How a swap meets the floor matters, so it is worth being precise. Uniswap v4 swaps already take a
 * `sqrtPriceLimitX96`, and {sqrtPriceFloorX96} returns exactly the value to pass: a swap carrying it fills as much as
 * the floor allows and stops there, which is the behaviour a seller wants. The `afterSwap` check is the backstop for
 * callers that pass no limit, and for those the swap reverts rather than partially filling. Routers should read the
 * floor; the revert exists so that a router which does not cannot break the invariant.
 *
 * One tick is one basis point to within rounding, so `offsetTicks = 2000` is a floor twenty percent below the high.
 *
 * @custom:slug ratchet-floor
 * @custom:family Curves
 * @custom:prior-art Floor prices are usually a treasury commitment (protocol-owned liquidity, OHM-style backing) or a
 * buyback hook that spends fees defending a level. Both depend on a balance and on whoever can move it. Enforcing a
 * monotone floor as an invariant of the pool, with no treasury and no key, is a different construction: nothing is
 * spent defending it and nothing can lower it.
 * @custom:limitation This guarantees the pool will not print below the floor. It does not guarantee anyone can sell
 * at the floor, because it holds no capital: once the price reaches the floor there is simply no more selling into
 * the pool, and a holder who wants out has to wait for the price to recover or trade elsewhere. It converts a
 * liquidity risk into a liquidity halt, honestly and predictably, but it does not make the risk disappear. A pool
 * that needs a real bid at the floor needs a treasury behind it, and this is not that.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract RatchetFloorHook is ForgeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice How far below the all-time-high tick the floor sits. Must be non-zero.
        uint24 offsetTicks;
    }

    /// @notice The state the ratchet keeps for each pool. Both fields only ever increase.
    struct Floor {
        int24 highWaterTick;
        int24 floorTick;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The high-water mark and the floor it implies, per pool.
    mapping(PoolId => Floor) public floorOf;

    /// @dev `offsetTicks` was zero, which would pin the floor to the current price and stop the pool trading down.
    error InvalidOffset();

    /// @dev The swap would leave the pool below its floor. Pass `sqrtPriceFloorX96` as the swap's price limit.
    error BelowFloor(int24 tick, int24 floorTick);

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 offsetTicks);

    /// @notice Emitted whenever a new high ratchets the floor upward. It is never emitted for a decline.
    event FloorRaised(PoolId indexed id, int24 highWaterTick, int24 floorTick);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.offsetTicks == 0) revert InvalidOffset();

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.offsetTicks);
    }

    /**
     * @notice The price limit a swap should carry to fill against the floor instead of reverting at it.
     * @dev Pass this as `sqrtPriceLimitX96` on a sell. The swap then fills as much as the floor allows and stops,
     * which is what a seller wants and what the `afterSwap` backstop cannot give them.
     */
    function sqrtPriceFloorX96(PoolId id) public view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(floorOf[id].floorTick);
    }

    /// @notice The floor tick for a pool. Monotone: this value never decreases.
    function floorTick(PoolId id) public view returns (int24) {
        return floorOf[id].floorTick;
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
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Requires a configuration, and sets the opening floor from the opening price.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        if (cfg.offsetTicks == 0) revert PoolNotConfigured();

        int24 opening = _clampTick(tick - int24(int256(uint256(cfg.offsetTicks))));
        floorOf[id] = Floor(tick, opening);
        emit FloorRaised(id, tick, opening);
        return this.afterInitialize.selector;
    }

    /// @dev Ratchets the floor on a new high, and refuses to leave the pool below it.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tick,,) = poolManager.getSlot0(id);

        Floor memory state = floorOf[id];
        if (tick < state.floorTick) revert BelowFloor(tick, state.floorTick);

        if (tick > state.highWaterTick) {
            int24 raised = _clampTick(tick - int24(int256(uint256(configOf[id].offsetTicks))));
            // The floor is a maximum over history, so a new high can only ever raise it.
            if (raised > state.floorTick) {
                floorOf[id] = Floor(tick, raised);
                emit FloorRaised(id, tick, raised);
            } else {
                floorOf[id].highWaterTick = tick;
            }
        }

        return (this.afterSwap.selector, 0);
    }

    /// @dev Keeps a derived tick inside the range Uniswap accepts, so a pool near the bottom cannot underflow it.
    function _clampTick(int24 tick) private pure returns (int24) {
        if (tick < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (tick > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return tick;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "RatchetFloor";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "ratchet-floor.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "price-floor";
        tags[1] = "launch";
        tags[2] = "no-admin";
        tags[3] = "oracle-free";
    }
}
