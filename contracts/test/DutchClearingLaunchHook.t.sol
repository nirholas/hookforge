// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DutchClearingLaunchHook} from "src/hooks/DutchClearingLaunchHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract DutchClearingLaunchHookTest is ForgeTest {
    DutchClearingLaunchHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint64 internal startTime;
    uint32 internal constant DURATION = 1 hours;

    /// @dev Q96 price of 1:1, and a start price four times that.
    uint160 internal constant PRICE_1_1 = uint160(1 << 96);
    uint160 internal constant START_PRICE = uint160(4 * (uint256(1) << 96));
    uint160 internal constant FLOOR_PRICE = uint160((uint256(1) << 96) / 2);

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);
        startTime = uint64(block.timestamp);

        hook = DutchClearingLaunchHook(
            deployHookTo(
                "src/hooks/DutchClearingLaunchHook.sol:DutchClearingLaunchHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG,
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // currency0 is the launched token, so buying it means paying currency1: zeroForOne == false.
        hook.configure(poolKey, _config());
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-60000, 60000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function _config() private view returns (DutchClearingLaunchHook.Config memory) {
        return DutchClearingLaunchHook.Config({
            startPriceX96: START_PRICE,
            floorPriceX96: FLOOR_PRICE,
            startTime: startTime,
            duration: DURATION,
            buyIsZeroForOne: false
        });
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "DutchClearingLaunch");
    }

    function test_configure_rejectsBadParameters() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;

        DutchClearingLaunchHook.Config memory cfg = _config();
        cfg.duration = 0;
        vm.expectRevert(DutchClearingLaunchHook.InvalidDuration.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.floorPriceX96 = START_PRICE + 1;
        vm.expectRevert(DutchClearingLaunchHook.FloorAboveStart.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.startTime = uint64(block.timestamp - 1);
        vm.expectRevert(DutchClearingLaunchHook.StartInThePast.selector);
        hook.configure(other, cfg);
    }

    function test_initialize_withoutConfig_reverts() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PoolConfigurable.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_theFloorDescendsLinearlyAndThenStops() public view {
        assertEq(hook.floorAt(poolId, startTime), START_PRICE, "the schedule opens at the start price");
        assertEq(
            hook.floorAt(poolId, startTime + DURATION / 2),
            START_PRICE - (uint256(START_PRICE) - FLOOR_PRICE) / 2,
            "halfway through it is halfway down"
        );
        assertEq(hook.floorAt(poolId, startTime + DURATION), FLOOR_PRICE, "it lands on the floor");
        assertEq(hook.floorAt(poolId, startTime + 30 days), FLOOR_PRICE, "and stays there");
    }

    function test_theFloorIsMonotonic() public view {
        uint256 previous = type(uint256).max;
        for (uint256 t = 0; t <= DURATION; t += 60) {
            uint256 floor = hook.floorAt(poolId, startTime + t);
            assertLe(floor, previous, "the floor must never rise");
            assertGe(floor, FLOOR_PRICE);
            previous = floor;
        }
    }

    function test_buyingBelowTheFloorReverts_earlyInTheSchedule() public {
        // The pool is at 1:1 but the schedule is still asking 4:1, so no buy can clear yet.
        vm.expectRevert();
        swap(poolKey, false, -1e15, ZERO_BYTES);

        assertFalse(hook.cleared(poolId), "nothing should have cleared");
    }

    function test_sellingIsNeverRestricted() public {
        // The whole schedule is binding on buys, and selling must still work at every point in it. Nobody should be
        // trapped in a position by the launch mechanism.
        BalanceDelta delta = swap(poolKey, true, -1e15, ZERO_BYTES);
        assertLt(delta.amount0(), 0, "the sell should have executed");
        assertGt(delta.amount1(), 0);
    }

    function test_theAuctionClearsOnceTheFloorFallsToThePool() public {
        // The floor runs from 4.0 down to 0.5, so it crosses the pool's 1:1 price at six sevenths of the way
        // through. Warp past that and the first buy clears.
        vm.warp(startTime + (DURATION * 19) / 20);
        assertLt(hook.currentFloorX96(poolId), uint256(PRICE_1_1), "the floor should have fallen past the pool price");

        BalanceDelta delta = swap(poolKey, false, -1e15, ZERO_BYTES);
        assertGt(delta.amount0(), 0, "the buy should have executed");

        assertTrue(hook.cleared(poolId), "the auction should have cleared");
        assertGt(hook.clearingPriceX96(poolId), 0);
        assertGe(hook.clearingPriceX96(poolId), hook.currentFloorX96(poolId), "it cleared at or above the floor");
    }

    function test_clearingIsRecordedOnce() public {
        vm.warp(startTime + (DURATION * 19) / 20);
        swap(poolKey, false, -1e15, ZERO_BYTES);
        uint256 first = hook.clearingPriceX96(poolId);

        swap(poolKey, false, -1e15, ZERO_BYTES);
        assertEq(hook.clearingPriceX96(poolId), first, "the clearing price is the first one, not the latest");
    }

    function test_afterTheScheduleExpiresNothingIsRestricted() public {
        vm.warp(startTime + DURATION + 1);
        assertFalse(hook.scheduleActive(poolId), "the schedule should have expired");

        // A buy that would have been far below the early floor now executes freely.
        BalanceDelta delta = swap(poolKey, false, -1e15, ZERO_BYTES);
        assertGt(delta.amount0(), 0, "the pool should be ordinary once the schedule is done");
    }

    function test_snipingTheFirstBlockBuysNothing() public {
        // The property the design exists for: at t=0 the floor is the start price, so there is no discount in the
        // first block for anyone to race for.
        assertEq(hook.floorAt(poolId, startTime), START_PRICE);
        vm.expectRevert();
        swap(poolKey, false, -1e18, ZERO_BYTES);
    }

    function testFuzz_noBuyEverClearsBelowTheFloor(uint32 offset, uint96 size) public {
        uint256 t = bound(offset, 0, DURATION);
        uint256 amount = bound(size, 1e12, 1e16);
        vm.warp(startTime + t);

        uint256 floor = hook.currentFloorX96(poolId);
        try this.buy(amount) returns (BalanceDelta delta) {
            uint256 paid = uint256(uint128(-delta.amount1()));
            uint256 received = uint256(uint128(delta.amount0()));
            assertGe((paid << 96) / received, floor, "a fill that landed must have been at or above the floor");
        } catch {
            // Refused, which is the other correct outcome.
        }
    }

    /// @dev `swap` is internal to the harness; this exposes it so a fuzz run can catch the revert.
    function buy(uint256 amount) external returns (BalanceDelta) {
        return swap(poolKey, false, -int256(amount), ZERO_BYTES);
    }
}
