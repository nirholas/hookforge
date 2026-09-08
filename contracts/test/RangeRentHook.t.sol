// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {RangeRentHook} from "src/hooks/RangeRentHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract RangeRentHookTest is ForgeTest {
    RangeRentHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    IERC20 internal rentToken;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    int24 internal constant RANGE_WIDTH = 600;
    uint128 internal constant RENT_PER_SECOND = 1e12;
    uint32 internal constant MIN_TERM = 1 hours;
    uint32 internal constant MAX_TERM = 7 days;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_000_000);

        hook = RangeRentHook(
            deployHookTo("src/hooks/RangeRentHook.sol:RangeRentHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        rentToken = IERC20(Currency.unwrap(currency1));

        hook.configure(
            poolKey,
            RangeRentHook.Config({
                rangeWidth: RANGE_WIDTH,
                rentPerSecond: RENT_PER_SECOND,
                minTerm: MIN_TERM,
                maxTerm: MAX_TERM
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            deal(address(rentToken), who, 1_000e18);
            vm.prank(who);
            rentToken.approve(address(hook), type(uint256).max);
        }
        // The router is what actually calls the pool, so it is the account a lease has to name. See the note on
        // caller identity in the hook: exclusivity can only ever be enforced against the caller v4 reports.
        deal(address(rentToken), address(modifyLiquidityRouter), 1_000e18);
        vm.prank(address(modifyLiquidityRouter));
        rentToken.approve(address(hook), type(uint256).max);
    }

    function _lease(address who, int256 range, uint32 term) private {
        vm.prank(who);
        hook.lease(poolKey, range, term);
    }

    function _add(int24 lower, int24 upper) private {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(lower, upper, 1e18, bytes32(0)), ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "RangeRent");
    }

    // --- configuration ------------------------------------------------------

    function test_configure_rejectsAWidthThatIsNotWholeTickSpacings() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(RangeRentHook.InvalidRangeWidth.selector);
        hook.configure(
            other,
            RangeRentHook.Config({rangeWidth: 55, rentPerSecond: RENT_PER_SECOND, minTerm: MIN_TERM, maxTerm: MAX_TERM})
        );
    }

    function test_configure_rejectsFreeExclusivity() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(RangeRentHook.InvalidTerms.selector);
        hook.configure(
            other, RangeRentHook.Config({rangeWidth: 60, rentPerSecond: 0, minTerm: MIN_TERM, maxTerm: MAX_TERM})
        );
    }

    function test_anUnconfiguredPoolCannotBeInitialized() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // --- the commons --------------------------------------------------------

    function test_anUnleasedRangeIsOpenToEverybody() public {
        _add(-600, 600);
        _add(-600, 600);
        // Two adds to the same unleased range both succeed, which is what a commons means.
        assertEq(_holder(0), address(0), "and nobody holds it");
    }

    function _holder(int256 range) private view returns (address holder) {
        (holder,) = hook.leaseOf(poolId, range);
    }

    // --- leasing ------------------------------------------------------------

    function test_leasingARangeChargesRentForTheTerm() public {
        uint256 before = rentToken.balanceOf(alice);
        _lease(alice, 0, MIN_TERM);

        assertEq(rentToken.balanceOf(alice), before - uint256(RENT_PER_SECOND) * MIN_TERM, "paid by the second");
        assertEq(hook.pendingRent(poolId), uint256(RENT_PER_SECOND) * MIN_TERM, "and the pool is owed it");
    }

    function test_aTermOutsideTheRangeIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RangeRentHook.TermOutOfRange.selector, MIN_TERM, MAX_TERM));
        hook.lease(poolKey, 0, MIN_TERM - 1);
    }

    function test_aHeldRangeCannotBeTakenMidTerm() public {
        _lease(alice, 0, MIN_TERM);
        vm.prank(bob);
        vm.expectRevert();
        hook.lease(poolKey, 0, MIN_TERM);
    }

    function test_anExpiredLeaseReadsAsVacant() public {
        _lease(alice, 0, MIN_TERM);
        (address holder,) = hook.heldBy(poolKey, 0);
        assertEq(holder, alice, "held while it runs");

        vm.warp(block.timestamp + MIN_TERM + 1);
        (holder,) = hook.heldBy(poolKey, 0);
        assertEq(holder, address(0), "and vacant once it does not");
    }

    function test_anExpiredRangeCanBeTakenBySomebodyElse() public {
        _lease(alice, 0, MIN_TERM);
        vm.warp(block.timestamp + MIN_TERM + 1);

        _lease(bob, 0, MIN_TERM);
        (address holder,) = hook.heldBy(poolKey, 0);
        assertEq(holder, bob, "the commons returned and was taken again");
    }

    /// @dev Renewing early must add to what is left rather than restarting, or renewing is a penalty.
    function test_renewingEarlyExtendsRatherThanResets() public {
        _lease(alice, 0, MIN_TERM);
        (, uint64 first) = hook.heldBy(poolKey, 0);

        vm.warp(block.timestamp + 60);
        _lease(alice, 0, MIN_TERM);
        (, uint64 second) = hook.heldBy(poolKey, 0);

        assertEq(second, first + MIN_TERM, "the second term begins where the first ends");
    }

    // --- exclusivity --------------------------------------------------------

    /// @dev The property the hook exists for: nobody else may provide in a leased range.
    function test_nobodyElseCanAddLiquidityToALeasedRange() public {
        _lease(alice, 0, MIN_TERM);
        vm.expectRevert();
        _add(0, 600);
    }

    function test_theLesseeCanAddLiquidityToTheirOwnRange() public {
        // The router is the account the pool sees, so the router is what holds the lease.
        _lease(address(modifyLiquidityRouter), 0, MIN_TERM);
        _add(0, 600);
        assertEq(_holder(0), address(modifyLiquidityRouter), "the holder provides freely");
    }

    function test_unleasedRangesAreStillOpenWhileOthersAreLeased() public {
        _lease(alice, 0, MIN_TERM);
        // Range -1 covers ticks below zero and is nobody's.
        _add(-600, -60);
    }

    /// @dev A wide position must not be able to add straight through a leased range in the middle of it.
    function test_aWidePositionCannotStraddleALeasedRange() public {
        _lease(alice, 0, MIN_TERM);
        vm.expectRevert();
        _add(-1200, 1200);
    }

    function test_aPositionTooWideToCheckIsRefused() public {
        // v4 wraps a hook's revert, so the selector is not visible at this boundary.
        vm.expectRevert();
        _add(-60000, 60000);
    }

    function test_liquidityIsAllowedAgainOnceTheLeaseExpires() public {
        _lease(alice, 0, MIN_TERM);
        vm.warp(block.timestamp + MIN_TERM + 1);
        _add(0, 600);
    }

    // --- rent ---------------------------------------------------------------

    function test_rentIsDonatedToProviders() public {
        _add(-1200, 1200);
        _lease(alice, 6, MIN_TERM); // a range far from the price, so the add above is unaffected

        uint256 pending = hook.pendingRent(poolId);
        assertGt(pending, 0, "there is rent to settle");

        uint256 poolBefore = rentToken.balanceOf(address(manager));
        hook.settleRent(poolKey);

        assertEq(hook.pendingRent(poolId), 0, "the pot is emptied");
        assertGe(rentToken.balanceOf(address(manager)) - poolBefore, pending, "and the pool holds it");
    }

    function test_settlingNothingReverts() public {
        vm.expectRevert(RangeRentHook.NothingToSettle.selector);
        hook.settleRent(poolKey);
    }

    // --- invariants ---------------------------------------------------------

    /// @dev Rent is always exactly the per-second rate times the term, whatever the term.
    function testFuzz_rentIsLinearInTheTerm(uint32 term) public {
        term = uint32(bound(term, MIN_TERM, MAX_TERM));

        uint256 before = rentToken.balanceOf(alice);
        _lease(alice, 3, term);
        assertEq(before - rentToken.balanceOf(alice), uint256(RENT_PER_SECOND) * term, "no discount and no premium");
    }

    /// @dev However the ticks fall, a leased range excludes everybody except its holder.
    function testFuzz_aLeasedRangeExcludesEverybodyElse(int24 lower) public {
        lower = int24(bound(lower, -540, 540) / 60 * 60);
        int24 upper = lower + 60;

        int256 range = hook.rangeOf(lower, RANGE_WIDTH);
        _lease(alice, range, MIN_TERM);

        vm.expectRevert();
        _add(lower, upper);
    }
}
