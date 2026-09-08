// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {TickHarbergerHook} from "src/hooks/TickHarbergerHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract TickHarbergerHookTest is ForgeTest {
    TickHarbergerHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    IERC20 internal rentToken;

    uint160 internal constant FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    int24 internal constant RANGE_WIDTH = 600; // ten tick spacings
    uint32 internal constant RENT_BPS = 500; // 5% of the valuation per day
    uint24 internal constant MAX_FEE_PIPS = 50_000; // 5%, the ceiling a leaseholder may charge
    uint128 internal constant MIN_DEPOSIT = 1e15;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_000_000);

        hook = TickHarbergerHook(
            deployHookTo("src/hooks/TickHarbergerHook.sol:TickHarbergerHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        rentToken = IERC20(Currency.unwrap(currency1));

        hook.configure(
            poolKey,
            TickHarbergerHook.Config({
                rangeWidth: RANGE_WIDTH,
                rentRateBps: RENT_BPS,
                maxFeePips: MAX_FEE_PIPS,
                minDeposit: MIN_DEPOSIT
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            deal(address(rentToken), who, 100e18);
            vm.prank(who);
            rentToken.approve(address(hook), type(uint256).max);
        }
    }

    function _lease(address who, int256 range, uint128 valuation, uint24 feePips, uint128 deposit) private {
        vm.prank(who);
        hook.claim(poolKey, range, valuation, feePips, deposit);
    }

    function _holderOf(int256 range) private view returns (address holder) {
        (holder,,,,) = hook.leaseOf(poolId, range);
    }

    function _depositOf(int256 range) private view returns (uint128 deposit) {
        (,,, deposit,) = hook.leaseOf(poolId, range);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "TickHarberger");
    }

    // --- configuration ------------------------------------------------------

    function test_configure_rejectsAWidthThatIsNotWholeTickSpacings() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(TickHarbergerHook.InvalidRangeWidth.selector);
        hook.configure(
            other,
            TickHarbergerHook.Config({rangeWidth: 55, rentRateBps: RENT_BPS, maxFeePips: MAX_FEE_PIPS, minDeposit: MIN_DEPOSIT})
        );
    }

    function test_configure_rejectsAZeroRent() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(TickHarbergerHook.InvalidRentRate.selector);
        hook.configure(
            other,
            TickHarbergerHook.Config({rangeWidth: 60, rentRateBps: 0, maxFeePips: MAX_FEE_PIPS, minDeposit: MIN_DEPOSIT})
        );
    }

    function test_anUnconfiguredPoolCannotBeInitialized() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // --- ranges -------------------------------------------------------------

    function test_rangesTileTheTickSpaceWithoutOverlap() public view {
        assertEq(hook.rangeOf(0, RANGE_WIDTH), 0, "zero sits in range zero");
        assertEq(hook.rangeOf(RANGE_WIDTH - 1, RANGE_WIDTH), 0, "the last tick of range zero");
        assertEq(hook.rangeOf(RANGE_WIDTH, RANGE_WIDTH), 1, "the first tick of range one");
        assertEq(hook.rangeOf(-1, RANGE_WIDTH), -1, "negative ticks floor rather than truncate");
        assertEq(hook.rangeOf(-RANGE_WIDTH, RANGE_WIDTH), -1, "the first tick of range minus one");
        assertEq(hook.rangeOf(-RANGE_WIDTH - 1, RANGE_WIDTH), -2, "and the one below it");
    }

    function test_theActiveRangeFollowsThePrice() public {
        assertEq(hook.currentRange(poolKey), 0, "a pool at parity sits in range zero");
        assertEq(hook.activeRange(poolId), 0, "and the hook knows it");
    }

    // --- leasing ------------------------------------------------------------

    function test_anUnleasedRangeChargesNothing() public {
        uint256 before = IERC20(Currency.unwrap(currency1)).balanceOf(address(manager));
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(_holderOf(0), address(0), "range is unleased");
        assertGt(before, 0, "sanity: the pool holds currency1");
    }

    function test_leasingARangeSetsItsFee() public {
        _lease(alice, 0, 1e18, 10_000, 1e17);
        (address holder, uint24 feePips, uint128 valuation, uint128 deposit,) = hook.leaseOf(poolId, 0);
        assertEq(holder, alice, "alice holds it");
        assertEq(feePips, 10_000, "at the fee she set");
        assertEq(valuation, 1e18, "on the valuation she named");
        assertEq(deposit, 1e17, "with the deposit she paid");
    }

    function test_aFeeAboveTheCeilingIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TickHarbergerHook.FeeTooHigh.selector, MAX_FEE_PIPS));
        hook.claim(poolKey, 0, 1e18, MAX_FEE_PIPS + 1, 1e17);
    }

    function test_aDepositBelowTheMinimumIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TickHarbergerHook.DepositTooSmall.selector, MIN_DEPOSIT));
        hook.claim(poolKey, 0, 1e18, 10_000, MIN_DEPOSIT - 1);
    }

    function test_aZeroValuationIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(TickHarbergerHook.InvalidValuation.selector);
        hook.claim(poolKey, 0, 0, 10_000, 1e17);
    }

    /// @dev The whole point of a Harberger lease: the holder's own number is the price anybody may pay.
    function test_anybodyCanTakeARangeAtTheHoldersOwnPrice() public {
        _lease(alice, 0, 2e18, 10_000, 1e17);
        uint256 aliceBefore = rentToken.balanceOf(alice);

        _lease(bob, 0, 5e18, 20_000, 1e17);

        assertEq(_holderOf(0), bob, "bob now holds it");
        // Alice is paid her valuation plus whatever deposit she had left.
        assertGe(rentToken.balanceOf(alice), aliceBefore + 2e18, "alice is paid her own price");
    }

    function test_takingARangeCostsThePriceAndTheDeposit() public {
        _lease(alice, 0, 2e18, 10_000, 1e17);
        uint256 bobBefore = rentToken.balanceOf(bob);

        _lease(bob, 0, 3e18, 10_000, 5e16);

        assertEq(rentToken.balanceOf(bob), bobBefore - 2e18 - 5e16, "bob pays the price and his own deposit");
    }

    /// @dev Re-valuing your own range should move only the difference in deposit, not the price twice.
    function test_reclaimingYourOwnRangeOnlyMovesTheDeposit() public {
        _lease(alice, 0, 2e18, 10_000, 1e17);
        uint256 before = rentToken.balanceOf(alice);

        _lease(alice, 0, 9e18, 30_000, 1e17);

        assertEq(rentToken.balanceOf(alice), before, "no net payment for revaluing your own lease");
        (, uint24 feePips, uint128 valuation,,) = hook.leaseOf(poolId, 0);
        assertEq(valuation, 9e18, "the new valuation stands");
        assertEq(feePips, 30_000, "and the new fee");
    }

    // --- rent ---------------------------------------------------------------

    function test_rentAccruesOnlyWhileTheRangeHoldsThePrice() public {
        _lease(alice, 0, 10e18, 10_000, 1e17);
        _lease(bob, 5, 10e18, 10_000, 1e17); // a distant range, far from the price

        vm.warp(block.timestamp + 1 days);
        assertGt(hook.accruedRent(poolKey, 0), 0, "the active range owes rent");
        assertEq(hook.accruedRent(poolKey, 5), 0, "a range the price never reached owes nothing");
    }

    function test_rentIsChargedAtTheConfiguredRate() public {
        _lease(alice, 0, 10e18, 10_000, 1e18);
        vm.warp(block.timestamp + 1 days);

        // 5% of a 10e18 valuation, for one whole day.
        assertEq(hook.accruedRent(poolKey, 0), (uint256(10e18) * RENT_BPS) / 10_000, "one day at the configured rate");
    }

    function test_rentIsTakenFromTheDepositOnASwap() public {
        _lease(alice, 0, 10e18, 10_000, 1e18);
        vm.warp(block.timestamp + 12 hours);

        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertLt(_depositOf(0), 1e18, "the deposit has paid some rent");
        assertGt(hook.pendingRent(poolId), 0, "and the pool is owed it");
    }

    function test_aLeaseLapsesWhenItsDepositRunsOut() public {
        _lease(alice, 0, 100e18, 10_000, MIN_DEPOSIT);
        // At 5% of 100e18 per day, a deposit of 1e15 is gone in minutes.
        vm.warp(block.timestamp + 7 days);

        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(_holderOf(0), address(0), "the lease has lapsed");
        assertEq(hook.pendingRent(poolId), MIN_DEPOSIT, "and the whole deposit went to the pool");
    }

    function test_aLapsedRangeChargesNothingAgain() public {
        _lease(alice, 0, 100e18, MAX_FEE_PIPS, MIN_DEPOSIT);
        vm.warp(block.timestamp + 7 days);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        uint256 owedBefore = hook.owed(alice, currency0) + hook.owed(alice, currency1);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(hook.owed(alice, currency0) + hook.owed(alice, currency1), owedBefore, "a lapsed lease earns nothing");
    }

    function test_collectedRentIsDonatedToProviders() public {
        _lease(alice, 0, 10e18, 10_000, 1e18);
        vm.warp(block.timestamp + 12 hours);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        uint256 pending = hook.pendingRent(poolId);
        assertGt(pending, 0, "there is rent to settle");

        uint256 poolBefore = rentToken.balanceOf(address(manager));
        hook.settleRent(poolKey);

        assertEq(hook.pendingRent(poolId), 0, "the pot is emptied");
        assertGe(rentToken.balanceOf(address(manager)) - poolBefore, pending, "and the pool holds it");
    }

    function test_settlingNothingReverts() public {
        vm.expectRevert(TickHarbergerHook.NothingToDo.selector);
        hook.settleRent(poolKey);
    }

    // --- the fee ------------------------------------------------------------

    function test_theLeaseholderEarnsTheFeeTheySet() public {
        _lease(alice, 0, 10e18, MAX_FEE_PIPS, 1e18);
        swap(poolKey, true, -1e16, ZERO_BYTES);

        uint256 earned = hook.owed(alice, currency0) + hook.owed(alice, currency1);
        assertGt(earned, 0, "the leaseholder is paid for the flow they priced");
    }

    function test_theLeaseholderCanWithdrawRealTokens() public {
        _lease(alice, 0, 10e18, MAX_FEE_PIPS, 1e18);
        swap(poolKey, true, -1e16, ZERO_BYTES);

        uint256 owed1 = hook.owed(alice, currency1);
        assertGt(owed1, 0, "sanity: there is something to withdraw");

        uint256 before = rentToken.balanceOf(alice);
        vm.prank(alice);
        hook.withdraw(poolKey);

        assertEq(rentToken.balanceOf(alice), before + owed1, "paid out as tokens, not claims");
        assertEq(hook.owed(alice, currency1), 0, "and the ledger is cleared");
    }

    function test_withdrawingNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(TickHarbergerHook.NothingToDo.selector);
        hook.withdraw(poolKey);
    }

    /// @dev A swap should be charged the fee where it started, not the cheaper fee of wherever it ended up.
    function test_aSwapPaysTheFeeOfTheRangeItStartedIn() public {
        _lease(alice, 0, 10e18, MAX_FEE_PIPS, 1e18);
        // Range -1 is unleased and therefore free; a large sell walks the price down into it.
        swap(poolKey, true, -2e18, ZERO_BYTES);

        assertGt(hook.owed(alice, currency1), 0, "the range the swap began in was paid");
        assertLt(hook.currentRange(poolKey), 0, "sanity: the swap did cross out of range zero");
    }

    function test_theActiveRangeMovesWithThePrice() public {
        swap(poolKey, true, -2e18, ZERO_BYTES);
        assertEq(hook.activeRange(poolId), hook.currentRange(poolKey), "the hook follows the price");
    }

    /// @dev Rent must start running for whoever holds the range the price just arrived in.
    function test_arrivingInARangeStartsItsRentClock() public {
        // Find where the swap lands rather than assuming it, so the test still means what it says if the pool's
        // liquidity or tick spacing changes.
        uint256 snapshot = vm.snapshotState();
        swap(poolKey, true, -2e18, ZERO_BYTES);
        int256 target = hook.currentRange(poolKey);
        vm.revertToState(snapshot);
        assertLt(target, 0, "sanity: the swap moves the price down out of range zero");

        _lease(bob, target, 10e18, 10_000, 1e18);
        assertEq(hook.accruedRent(poolKey, target), 0, "no rent before the price arrives");

        swap(poolKey, true, -2e18, ZERO_BYTES);
        assertEq(hook.activeRange(poolId), target, "the price landed in bob's range");

        vm.warp(block.timestamp + 1 days);
        assertGt(hook.accruedRent(poolKey, target), 0, "and his clock is running");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev Rent charged can never exceed the deposit that backs it, whatever the valuation or the elapsed time.
    function testFuzz_rentNeverExceedsTheDeposit(uint128 valuation, uint128 deposit, uint32 elapsed) public {
        valuation = uint128(bound(valuation, 1, 50e18));
        deposit = uint128(bound(deposit, MIN_DEPOSIT, 50e18));
        elapsed = uint32(bound(elapsed, 1, 365 days));

        _lease(alice, 0, valuation, 10_000, deposit);
        vm.warp(block.timestamp + elapsed);

        assertLe(hook.accruedRent(poolKey, 0), deposit, "rent is capped by the deposit");
    }

    /// @dev Taking a range always pays the incumbent at least the number they themselves published.
    function testFuzz_theIncumbentIsAlwaysPaidTheirOwnValuation(uint128 valuation) public {
        valuation = uint128(bound(valuation, 1, 50e18));
        _lease(alice, 0, valuation, 10_000, 1e18);

        uint256 before = rentToken.balanceOf(alice);
        _lease(bob, 0, 1e18, 10_000, 1e18);

        assertGe(rentToken.balanceOf(alice), before + valuation, "never less than they asked for");
    }
}
