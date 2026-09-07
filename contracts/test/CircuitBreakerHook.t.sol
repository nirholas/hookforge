// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {CircuitBreakerHook} from "src/hooks/CircuitBreakerHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";

contract CircuitBreakerHookTest is ForgeTest {
    CircuitBreakerHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant MAX_TICK_MOVE = 100; // one percent
    uint32 internal constant WINDOW = 60;
    uint32 internal constant COOLDOWN = 300;

    function setUp() public {
        setUpForge();

        hook = CircuitBreakerHook(
            deployHookTo(
                "src/hooks/CircuitBreakerHook.sol:CircuitBreakerHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, CircuitBreakerHook.Config(MAX_TICK_MOVE, WINDOW, COOLDOWN));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        // A range wide enough that a small swap barely moves the tick, so the tests exercise the breaker rather
        // than the edge of a narrow position.
        modifyLiquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "CircuitBreaker");
    }

    function test_referenceTakenAtInitialize() public view {
        (int24 tick, uint64 at) = hook.referenceOf(poolId);
        assertEq(tick, 0);
        assertEq(at, uint64(block.timestamp));
    }

    function test_initialize_withoutConfiguration_reverts() public {
        PoolKey memory unconfigured = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PoolConfigurable.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(unconfigured, SQRT_PRICE_1_1);
    }

    function test_configure_zeroField_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));
        vm.expectRevert(CircuitBreakerHook.InvalidConfig.selector);
        hook.configure(other, CircuitBreakerHook.Config(0, WINDOW, COOLDOWN));
    }

    function test_smallMove_doesNotTrip() public {
        swap(poolKey, true, -1e14, ZERO_BYTES);
        assertLe(hook.moveFromReference(poolId), MAX_TICK_MOVE);
        assertFalse(hook.isHalted(poolId));
    }

    function test_limitMove_halts() public {
        swap(poolKey, true, -1e18, ZERO_BYTES);

        assertGt(hook.moveFromReference(poolId), MAX_TICK_MOVE);
        assertTrue(hook.isHalted(poolId));
        assertEq(hook.haltedUntil(poolId), uint64(block.timestamp) + COOLDOWN);
    }

    function test_swapDuringHalt_reverts() public {
        swap(poolKey, true, -1e18, ZERO_BYTES);
        uint64 until = hook.haltedUntil(poolId);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(CircuitBreakerHook.PoolHalted.selector, until),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -1e14, ZERO_BYTES);
    }

    function test_liquidityCanLeaveDuringHalt() public {
        swap(poolKey, true, -1e18, ZERO_BYTES);
        assertTrue(hook.isHalted(poolId));

        // The property that makes a halt safe: anyone caught in the pool can still get out.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, -5e18, bytes32(0)), ZERO_BYTES
        );
    }

    function test_haltClearsItself() public {
        swap(poolKey, true, -1e18, ZERO_BYTES);
        assertTrue(hook.isHalted(poolId));

        vm.warp(block.timestamp + COOLDOWN);
        assertFalse(hook.isHalted(poolId));

        // The reference has also gone stale, so the first swap back rolls it to the new price and starts clean.
        swap(poolKey, false, -1e14, ZERO_BYTES);
        assertFalse(hook.isHalted(poolId));
    }

    function test_referenceRollsAfterWindow() public {
        swap(poolKey, true, -1e14, ZERO_BYTES);
        (int24 firstTick,) = hook.referenceOf(poolId);

        vm.warp(block.timestamp + WINDOW);
        swap(poolKey, true, -1e14, ZERO_BYTES);
        (int24 rolledTick, uint64 rolledAt) = hook.referenceOf(poolId);

        assertLt(rolledTick, firstTick, "reference follows the price into the new window");
        assertEq(rolledAt, uint64(block.timestamp));
    }

    function test_gradualMoveAcrossWindowsNeverTrips() public {
        // The same total distance, walked one window at a time, is not a limit move and must not halt the pool.
        for (uint256 i = 0; i < 6; i++) {
            swap(poolKey, true, -1e14, ZERO_BYTES);
            assertFalse(hook.isHalted(poolId));
            vm.warp(block.timestamp + WINDOW);
        }
    }
}
