// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {TradingCalendarHook} from "src/hooks/TradingCalendarHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract TradingCalendarHookTest is ForgeTest {
    TradingCalendarHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint32 internal constant OPEN = 13 hours + 30 minutes; // 09:30 New York in UTC (winter)
    uint32 internal constant CLOSE = 20 hours; // 16:00 New York in UTC (winter)
    uint32 internal constant RAMP = 30 minutes;
    uint24 internal constant SESSION_FEE = 500; // 0.05%
    uint24 internal constant CLOSED_FEE = 20_000; // 2%
    uint8 internal constant WEEKDAYS = 0x1F; // Monday..Friday

    /// @dev A Monday. 2024-01-01 00:00:00 UTC was a Monday.
    uint256 internal constant MONDAY_MIDNIGHT = 1_704_067_200;

    function setUp() public {
        setUpForge();

        hook = TradingCalendarHook(
            deployHookTo(
                "src/hooks/TradingCalendarHook.sol:TradingCalendarHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        hook.configure(poolKey, _config());
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function _config() private pure returns (TradingCalendarHook.Config memory) {
        return TradingCalendarHook.Config({
            openSecond: OPEN,
            closeSecond: CLOSE,
            rampSeconds: RAMP,
            sessionFee: SESSION_FEE,
            closedFee: CLOSED_FEE,
            daysMask: WEEKDAYS
        });
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "TradingCalendar");
    }

    function test_weekdayDetection() public view {
        assertTrue(hook.isTradingDay(poolId, MONDAY_MIDNIGHT), "Monday should trade");
        assertTrue(hook.isTradingDay(poolId, MONDAY_MIDNIGHT + 4 days), "Friday should trade");
        assertFalse(hook.isTradingDay(poolId, MONDAY_MIDNIGHT + 5 days), "Saturday should not trade");
        assertFalse(hook.isTradingDay(poolId, MONDAY_MIDNIGHT + 6 days), "Sunday should not trade");
    }

    function test_midSession_chargesSessionFee() public view {
        (uint24 fee, bool inSession) = hook.feeAt(poolId, MONDAY_MIDNIGHT + OPEN + 2 hours);
        assertEq(fee, SESSION_FEE);
        assertTrue(inSession);
    }

    function test_deepOvernight_chargesClosedFee() public view {
        (uint24 fee, bool inSession) = hook.feeAt(poolId, MONDAY_MIDNIGHT + 2 hours);
        assertEq(fee, CLOSED_FEE);
        assertFalse(inSession);
    }

    function test_weekend_chargesClosedFee() public view {
        (uint24 fee,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + 5 days + OPEN + 1 hours);
        assertEq(fee, CLOSED_FEE, "Saturday inside session hours is still closed");
    }

    function test_openRamp_isContinuousAndHalfwayAtHalfRamp() public view {
        // Half a ramp before the open, the fee should sit halfway between the two levels.
        (uint24 half,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + OPEN - RAMP / 2);
        assertEq(half, SESSION_FEE + (CLOSED_FEE - SESSION_FEE) / 2);

        // At the instant of the open it is the session fee, with no jump.
        (uint24 atOpen,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + OPEN);
        assertEq(atOpen, SESSION_FEE);

        // One second before the ramp begins it is still fully closed.
        (uint24 beforeRamp,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + OPEN - RAMP - 1);
        assertEq(beforeRamp, CLOSED_FEE);
    }

    function test_closeRamp_risesBackToClosedFee() public view {
        (uint24 half,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + CLOSE - RAMP / 2);
        assertEq(half, SESSION_FEE + (CLOSED_FEE - SESSION_FEE) / 2);

        (uint24 midSession,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + CLOSE - RAMP - 1);
        assertEq(midSession, SESSION_FEE);
    }

    function test_feeSurfaceHasNoCliff() public view {
        // Walk the whole trading day one minute at a time; the fee must never jump by more than one minute's
        // worth of ramp. This is the property the hook exists for.
        uint256 maxStep = uint256(CLOSED_FEE - SESSION_FEE) * 60 / RAMP + 1;
        (uint24 previous,) = hook.feeAt(poolId, MONDAY_MIDNIGHT);
        for (uint256 t = 60; t < 1 days; t += 60) {
            (uint24 current,) = hook.feeAt(poolId, MONDAY_MIDNIGHT + t);
            uint256 step = current > previous ? current - previous : previous - current;
            assertLe(step, maxStep, "fee surface jumped");
            previous = current;
        }
    }

    function test_swap_overnightCostsMoreThanMidSession() public {
        vm.warp(MONDAY_MIDNIGHT + OPEN + 2 hours);
        BalanceDelta inSession = swap(poolKey, true, -1e15, ZERO_BYTES);

        vm.warp(MONDAY_MIDNIGHT + 2 hours);
        BalanceDelta overnight = swap(poolKey, true, -1e15, ZERO_BYTES);

        assertEq(inSession.amount0(), overnight.amount0(), "inputs differ");
        assertLt(overnight.amount1(), inSession.amount1(), "an overnight swap should receive less");
    }

    function test_swap_neverReverts_whenClosed() public {
        // The point of the design: a closed pool is expensive, never broken.
        vm.warp(MONDAY_MIDNIGHT + 6 days + 3 hours); // Sunday, deep in the weekend
        BalanceDelta delta = swap(poolKey, true, -1e15, ZERO_BYTES);
        assertLt(delta.amount0(), 0, "swap should still execute on a closed day");
        assertGt(delta.amount1(), 0, "swap should still return output on a closed day");
    }

    function test_overnightSession_wrapsMidnight() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        TradingCalendarHook.Config memory cfg = _config();
        cfg.openSecond = 22 hours;
        cfg.closeSecond = 6 hours; // wraps midnight
        hook.configure(other, cfg);
        manager.initialize(other, SQRT_PRICE_1_1);

        PoolId id = other.toId();
        (, bool beforeMidnight) = hook.feeAt(id, MONDAY_MIDNIGHT + 23 hours);
        (, bool afterMidnight) = hook.feeAt(id, MONDAY_MIDNIGHT + 1 days + 2 hours);
        (, bool midday) = hook.feeAt(id, MONDAY_MIDNIGHT + 12 hours);
        assertTrue(beforeMidnight, "23:00 is inside a 22:00-06:00 session");
        assertTrue(afterMidnight, "02:00 is inside a 22:00-06:00 session");
        assertFalse(midday, "12:00 is outside a 22:00-06:00 session");
    }

    function test_configure_rejectsBadParameters() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        TradingCalendarHook.Config memory cfg = _config();

        cfg.openSecond = 86_400;
        vm.expectRevert(TradingCalendarHook.InvalidSecondOfDay.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.daysMask = 0;
        vm.expectRevert(TradingCalendarHook.NoTradingDays.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.closedFee = SESSION_FEE - 1;
        vm.expectRevert(TradingCalendarHook.ClosedFeeBelowSessionFee.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.rampSeconds = 8 hours; // longer than half the session
        vm.expectRevert(TradingCalendarHook.RampTooLong.selector);
        hook.configure(other, cfg);
    }

    function testFuzz_feeAlwaysWithinBounds(uint256 timestamp) public view {
        timestamp = bound(timestamp, MONDAY_MIDNIGHT, MONDAY_MIDNIGHT + 30 days);
        (uint24 fee,) = hook.feeAt(poolId, timestamp);
        assertGe(fee, SESSION_FEE);
        assertLe(fee, CLOSED_FEE);
    }
}
