// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {RatchetFloorHook} from "src/hooks/RatchetFloorHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";

contract RatchetFloorHookTest is ForgeTest {
    RatchetFloorHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant OFFSET = 500; // the floor sits five percent below the all-time high

    function setUp() public {
        setUpForge();

        hook = RatchetFloorHook(
            deployHookTo(
                "src/hooks/RatchetFloorHook.sol:RatchetFloorHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, RatchetFloorHook.Config(OFFSET));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-30000, 30000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    /// @dev An external entry point, so a test can `try` a sell that the floor may refuse.
    function doSwap(bool zeroForOne, int256 amountSpecified) external {
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "RatchetFloor");
    }

    function test_openingFloorIsSetFromTheOpeningPrice() public view {
        (int24 highWater, int24 floor) = hook.floorOf(poolId);
        assertEq(highWater, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(floor, -int24(int256(uint256(OFFSET))));
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

    function test_configure_zeroOffset_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));
        vm.expectRevert(RatchetFloorHook.InvalidOffset.selector);
        hook.configure(other, RatchetFloorHook.Config(0));
    }

    function test_aRallyRaisesTheFloorPermanently() public {
        int24 before = hook.floorTick(poolId);

        swap(poolKey, false, -2e18, ZERO_BYTES); // buy: pushes the tick up
        int24 raised = hook.floorTick(poolId);
        assertGt(raised, before, "a new high must ratchet the floor");

        // Selling back down does not lower it. The sell carries the floor as its price limit, so it fills as far as
        // the floor allows and stops there, which is the path a router should take.
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -5e18, sqrtPriceLimitX96: hook.sqrtPriceFloorX96(poolId)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertEq(hook.floorTick(poolId), raised, "the floor never moves down");
    }

    function test_theFloorNeverFallsAcrossManyTrades() public {
        int24 highest = hook.floorTick(poolId);

        for (uint256 i = 0; i < 8; i++) {
            bool buy = i % 3 != 2;
            try this.doSwap(!buy, -3e17) {} catch {}

            int24 current = hook.floorTick(poolId);
            assertGe(current, highest, "the floor moved down");
            highest = current;
        }
    }

    function test_sellingThroughTheFloorReverts() public {
        // Push the price up so the floor ratchets well above the pool's starting point, then try to sell far below it.
        swap(poolKey, false, -3e18, ZERO_BYTES);
        assertGt(hook.floorTick(poolId), 0);

        vm.expectRevert();
        swap(poolKey, true, -8e18, ZERO_BYTES);
    }

    function test_sellingWithTheFloorAsPriceLimitFillsInstead() public {
        swap(poolKey, false, -3e18, ZERO_BYTES);
        uint160 limit = hook.sqrtPriceFloorX96(poolId);

        // The seller stops at the floor and keeps the fill, rather than being refused outright. This is the path a
        // router should take, and the reason the revert is only a backstop.
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -8e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertGe(poolSqrtPrice(poolKey), limit, "the pool stopped at the floor rather than crossing it");
    }

    function test_floorPriceMatchesFloorTick() public view {
        assertEq(hook.sqrtPriceFloorX96(poolId), TickMath.getSqrtPriceAtTick(hook.floorTick(poolId)));
    }

    function test_liquidityCanLeaveAtTheFloor() public {
        swap(poolKey, false, -3e18, ZERO_BYTES);

        // The floor constrains price, never withdrawal.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-30000, 30000, -5e18, bytes32(0)), ZERO_BYTES
        );
    }

    function testFuzz_floorIsAlwaysOffsetBelowTheHighWater(int128 size) public {
        int256 amount = -int256(bound(int256(size), 1e15, 4e18));
        try this.doSwap(false, amount) {} catch {}

        (int24 highWater, int24 floor) = hook.floorOf(poolId);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(floor, highWater - int24(int256(uint256(OFFSET))) + 1);
        assertGe(highWater, floor);
    }
}
