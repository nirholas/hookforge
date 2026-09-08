// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {StreamDCAHook} from "src/hooks/StreamDCAHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract StreamDCAHookTest is ForgeTest {
    StreamDCAHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    IERC20 internal token0;
    IERC20 internal token1;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG);

    uint64 internal constant PERIOD = 1 days;
    uint128 internal constant PER_PERIOD = 1e18;
    uint128 internal constant BUDGET = 20e18;
    uint32 internal constant PERIODS = 10;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_000_000);

        hook = StreamDCAHook(
            deployHookTo("src/hooks/StreamDCAHook.sol:StreamDCAHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        token0 = IERC20(Currency.unwrap(currency0));
        token1 = IERC20(Currency.unwrap(currency1));

        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-24000, 24000, 5e19, bytes32(0)), ZERO_BYTES
        );

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            deal(address(token0), who, 1000e18);
            deal(address(token1), who, 1000e18);
            vm.startPrank(who);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _open(address who, bool zeroForOne) private returns (uint256 id) {
        vm.prank(who);
        id = hook.open(poolKey, zeroForOne, BUDGET, PER_PERIOD, PERIOD, PERIODS);
    }

    function _stream(uint256 id) private view returns (StreamDCAHook.Stream memory s) {
        (
            address owner,
            bool zeroForOne,
            uint128 remaining,
            uint128 acquired,
            uint128 targetPerPeriod,
            uint64 periodLength,
            uint64 startedAt,
            uint32 periodsDone,
            uint32 periods
        ) = hook.streamOf(poolId, id);
        s = StreamDCAHook.Stream(
            owner, zeroForOne, remaining, acquired, targetPerPeriod, periodLength, startedAt, periodsDone, periods
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "StreamDCA");
    }

    // --- opening and closing ------------------------------------------------

    function test_openingPullsTheWholeBudget() public {
        uint256 before = token0.balanceOf(alice);
        _open(alice, true);
        assertEq(token0.balanceOf(alice), before - BUDGET, "the budget is held by the hook");
        assertEq(_stream(0).remaining, BUDGET, "and recorded as unspent");
    }

    function test_openingRejectsAnEmptyStream() public {
        vm.prank(alice);
        vm.expectRevert(StreamDCAHook.InvalidStream.selector);
        hook.open(poolKey, true, 0, PER_PERIOD, PERIOD, PERIODS);
    }

    function test_openingRejectsAZeroLengthPeriod() public {
        vm.prank(alice);
        vm.expectRevert(StreamDCAHook.InvalidStream.selector);
        hook.open(poolKey, true, BUDGET, PER_PERIOD, 0, PERIODS);
    }

    function test_onlyTheOwnerCanCloseAStream() public {
        _open(alice, true);
        vm.prank(bob);
        vm.expectRevert(StreamDCAHook.NotYourStream.selector);
        hook.close(poolKey, 0);
    }

    function test_closingRefundsTheUnspentBudget() public {
        _open(alice, true);
        uint256 before = token0.balanceOf(alice);

        vm.prank(alice);
        hook.close(poolKey, 0);

        assertEq(token0.balanceOf(alice), before + BUDGET, "an untouched stream refunds everything");
        assertEq(_stream(0).owner, address(0), "and the stream is gone");
    }

    function test_closingPaysOutWhatTheStreamBought() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        uint128 acquired = _stream(0).acquired;
        assertGt(acquired, 0, "sanity: the stream bought something");

        uint256 before = token1.balanceOf(alice);
        vm.prank(alice);
        hook.close(poolKey, 0);
        assertEq(token1.balanceOf(alice), before + acquired, "paid out as real tokens");
    }

    // --- the schedule -------------------------------------------------------

    function test_nothingIsDueBeforeTheFirstPeriodEnds() public {
        _open(alice, true);
        assertEq(hook.periodsDue(poolKey, 0), 0, "no period has passed");
        assertEq(hook.spendDue(poolKey, 0), 0, "so nothing is owed");
    }

    function test_theFirstPeriodBuysTheTargetAmount() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);

        assertEq(hook.periodsDue(poolKey, 0), 1, "one period is due");
        // The position is worth nothing yet, so the first buy is the whole target.
        assertEq(hook.spendDue(poolKey, 0), PER_PERIOD, "the first period buys the whole target");
    }

    function test_missedPeriodsAreCaughtUpAtOnce() public {
        _open(alice, true);
        vm.warp(block.timestamp + 3 * PERIOD);

        assertEq(hook.periodsDue(poolKey, 0), 3, "three periods are due");
        assertEq(hook.spendDue(poolKey, 0), 3 * PER_PERIOD, "and they are caught up together");
    }

    function test_theScheduleStopsAtTheFinalPeriod() public {
        _open(alice, true);
        vm.warp(block.timestamp + 100 * PERIOD);
        assertEq(hook.periodsDue(poolKey, 0), PERIODS, "never more periods than the stream has");
    }

    function test_spendIsCappedByTheRemainingBudget() public {
        vm.prank(alice);
        hook.open(poolKey, true, 2e18, PER_PERIOD, PERIOD, PERIODS);
        vm.warp(block.timestamp + 10 * PERIOD);
        assertEq(hook.spendDue(poolKey, 0), 2e18, "a stream never spends past its budget");
    }

    // --- value averaging ----------------------------------------------------

    /// @dev The whole reason this is not dollar-cost averaging: a cheaper price means a larger buy.
    function test_aFallingPriceMakesTheNextPeriodBuyMore() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        uint256 firstSpend = BUDGET - _stream(0).remaining;
        assertGt(firstSpend, 0, "sanity: the first period bought");

        // Selling currency1 into the pool makes currency1 cheap in currency0 terms, so what alice holds is now
        // worth less than she paid and her position is behind its target.
        swap(poolKey, false, -20e18, ZERO_BYTES);

        vm.warp(block.timestamp + PERIOD);
        uint256 secondSpend = hook.spendDue(poolKey, 0);
        assertGt(secondSpend, PER_PERIOD, "a position behind its target buys more than one period's worth");
    }

    /// @dev And the mirror image, which is the half that dollar-cost averaging cannot do at all.
    function test_aRisingPriceMakesTheNextPeriodBuyLess() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        // The other way: selling currency0 makes currency1 dearer, so alice's holding is worth more than she paid.
        swap(poolKey, true, -20e18, ZERO_BYTES);

        vm.warp(block.timestamp + PERIOD);
        uint256 secondSpend = hook.spendDue(poolKey, 0);
        assertLt(secondSpend, PER_PERIOD, "a position ahead of its target buys less");
    }

    /// @dev Far enough ahead and the right answer is to buy nothing, and to say the period is done.
    function test_aPositionFarAheadBuysNothingAndStillAdvances() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        swap(poolKey, true, -60e18, ZERO_BYTES);
        vm.warp(block.timestamp + PERIOD);

        uint256 spendBefore = hook.spendDue(poolKey, 0);
        uint128 remainingBefore = _stream(0).remaining;
        hook.poke(poolKey);

        assertEq(spendBefore, 0, "nothing was owed");
        assertEq(_stream(0).remaining, remainingBefore, "and nothing was spent");
        assertEq(_stream(0).periodsDone, 2, "but the period is settled rather than left hanging");
    }

    // --- settlement ---------------------------------------------------------

    function test_aStreamSettlesInsideSomebodyElsesSwap() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);

        assertEq(_stream(0).acquired, 0, "nothing bought yet");
        swap(poolKey, false, -1e15, ZERO_BYTES);
        assertGt(_stream(0).acquired, 0, "an unrelated swap settled it");
    }

    function test_pokingSettlesWithoutASwapper() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);
        assertGt(_stream(0).acquired, 0, "a pool with no flow can still be caught up");
    }

    function test_pokingAnIdleStreamDoesNothing() public {
        _open(alice, true);
        hook.poke(poolKey);
        assertEq(_stream(0).acquired, 0, "nothing was due");
        assertEq(_stream(0).remaining, BUDGET, "and nothing was spent");
    }

    /// @dev Two streams due together must be filled at one price, not at each other's expense.
    function test_streamsDueTogetherShareOnePrice() public {
        _open(alice, true);
        _open(bob, true);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        StreamDCAHook.Stream memory a = _stream(0);
        StreamDCAHook.Stream memory b = _stream(1);
        assertEq(BUDGET - a.remaining, BUDGET - b.remaining, "identical streams spend identically");
        assertApproxEqAbs(a.acquired, b.acquired, 1, "and receive the same, to within a wei of rounding");
    }

    function test_streamsInOppositeDirectionsBothSettle() public {
        _open(alice, true);
        _open(bob, false);
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        assertGt(_stream(0).acquired, 0, "the buyer of currency1 filled");
        assertGt(_stream(1).acquired, 0, "and so did the buyer of currency0");
    }

    /// @dev A settlement runs a swap through the same pool, which re-enters this hook. It must not recurse.
    function test_settlementDoesNotRecurse() public {
        _open(alice, true);
        vm.warp(block.timestamp + PERIOD);
        // Would run out of gas or double-spend the stream if the guard were missing.
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(_stream(0).periodsDone, 1, "settled exactly once");
    }

    function test_workPerSwapIsBounded() public {
        uint256 many = hook.MAX_PER_SWAP() + 4;
        for (uint256 i = 0; i < many; i++) {
            vm.prank(alice);
            hook.open(poolKey, true, 1e18, 1e17, PERIOD, PERIODS);
        }
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);

        uint256 settled;
        for (uint256 i = 0; i < many; i++) {
            if (_stream(i).periodsDone > 0) settled++;
        }
        assertEq(settled, hook.MAX_PER_SWAP(), "one pass settles exactly the cap, no more");
    }

    /// @dev And the ones it did not reach must be reached next time, rather than starved forever.
    function test_theRestAreCaughtUpOnTheNextPass() public {
        uint256 many = hook.MAX_PER_SWAP() + 4;
        for (uint256 i = 0; i < many; i++) {
            vm.prank(alice);
            hook.open(poolKey, true, 1e18, 1e17, PERIOD, PERIODS);
        }
        vm.warp(block.timestamp + PERIOD);
        hook.poke(poolKey);
        hook.poke(poolKey);

        for (uint256 i = 0; i < many; i++) {
            assertGt(_stream(i).periodsDone, 0, "every stream was reached within two passes");
        }
    }

    // --- invariants ---------------------------------------------------------

    /// @dev A stream can never spend more than it was funded with, however the price moves.
    function testFuzz_aStreamNeverOverspends(uint256 shock, uint32 elapsed) public {
        uint256 size = bound(shock, 1e17, 30e18);
        elapsed = uint32(bound(elapsed, 1, 40 days));

        _open(alice, true);
        swap(poolKey, true, -int256(size), ZERO_BYTES);
        vm.warp(block.timestamp + elapsed);
        hook.poke(poolKey);

        StreamDCAHook.Stream memory s = _stream(0);
        assertLe(BUDGET - s.remaining, BUDGET, "spent no more than the budget");
        assertLe(s.periodsDone, PERIODS, "and never ran past its schedule");
    }

    /// @dev Whatever it bought must still be there to withdraw.
    function testFuzz_everythingBoughtIsWithdrawable(uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, uint256(PERIOD), 40 days));
        _open(alice, true);
        vm.warp(block.timestamp + elapsed);
        hook.poke(poolKey);

        StreamDCAHook.Stream memory s = _stream(0);
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        vm.prank(alice);
        hook.close(poolKey, 0);

        assertEq(token1.balanceOf(alice), before1 + s.acquired, "all of it came back");
        assertEq(token0.balanceOf(alice), before0 + s.remaining, "along with what was never spent");
    }
}
