// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VarianceSwapHook} from "src/hooks/VarianceSwapHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract VarianceSwapHookTest is ForgeTest {
    VarianceSwapHook internal hook;
    PoolKey internal poolKey;
    IERC20 internal collateral;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    uint256 internal constant STRIKE = 20; // squared ticks per second the premium is priced at
    uint256 internal constant CAP = 200; // the rate at which a note pays its whole notional
    uint64 internal constant MIN_TERM = 1 hours;
    uint64 internal constant MAX_TERM = 30 days;

    address internal seller = address(0x5E11E2);
    address internal buyer = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_000_000);

        hook = VarianceSwapHook(_deploy(0x4444));
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-24000, 24000, 5e19, bytes32(0)), ZERO_BYTES
        );

        collateral = IERC20(Currency.unwrap(currency1));
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? seller : buyer;
            deal(address(collateral), who, 10_000e18);
            vm.prank(who);
            collateral.approve(address(hook), type(uint256).max);
        }
    }

    function _deploy(uint160 namespace) private returns (address) {
        return deployHookToNamespace(
            "src/hooks/VarianceSwapHook.sol:VarianceSwapHook",
            FLAGS,
            abi.encode(address(manager), STRIKE, CAP, MIN_TERM, MAX_TERM, "Variance Vault", "VVAULT"),
            namespace
        );
    }

    function _fund(uint256 amount) private {
        vm.prank(seller);
        hook.deposit(amount);
    }

    /// @dev Moves the price back and forth, which is what produces variance.
    function _shake(uint256 times, int256 size) private {
        for (uint256 i = 0; i < times; i++) {
            swap(poolKey, i % 2 == 0, -size, ZERO_BYTES);
            vm.warp(block.timestamp + 60);
        }
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "VarianceSwap");
    }

    // --- construction -------------------------------------------------------

    function test_constructor_rejectsAStrikeAtOrAboveTheCap() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/VarianceSwapHook.sol:VarianceSwapHook",
            FLAGS,
            abi.encode(address(manager), CAP, CAP, MIN_TERM, MAX_TERM, "n", "s"),
            0x1001
        );
    }

    function test_theHookBindsToOnePoolOnly() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_theCollateralIsThePoolsSecondCurrency() public view {
        assertEq(Currency.unwrap(hook.collateral()), Currency.unwrap(currency1), "bound at initialization");
    }

    // --- measuring variance -------------------------------------------------

    function test_aQuietPoolHasNoVariance() public view {
        assertEq(hook.cumulativeVariance(), 0, "nothing has moved");
    }

    function test_movingThePriceAccumulatesVariance() public {
        _shake(4, 2e18);
        assertGt(hook.cumulativeVariance(), 0, "a moving pool has variance");
    }

    /// @dev The measure has to be of the path, not the endpoints: a round trip is not a quiet market.
    function test_aRoundTripStillCountsAsVariance() public {
        swap(poolKey, true, -5e18, ZERO_BYTES);
        vm.warp(block.timestamp + 60);
        swap(poolKey, false, -5e18, ZERO_BYTES);
        vm.warp(block.timestamp + 60);
        // A third swap is needed to observe the second one's move, since sampling happens before a swap.
        swap(poolKey, true, -1e15, ZERO_BYTES);

        assertGt(hook.cumulativeVariance(), 0, "the path had variance even though the price came back");
    }

    function test_aBiggerMoveContributesMoreThanLinearly() public {
        swap(poolKey, true, -2e18, ZERO_BYTES);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        uint256 small = hook.cumulativeVariance();

        VarianceSwapHook other = VarianceSwapHook(_deploy(0x5555));
        PoolKey memory key2 = PoolKey(currency0, currency1, 500, 10, IHooks(address(other)));
        manager.initialize(key2, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key2, ModifyLiquidityParams(-24000, 24000, 5e19, bytes32(0)), ZERO_BYTES);
        swap(key2, true, -4e18, ZERO_BYTES);
        swap(key2, true, -1e15, ZERO_BYTES);

        assertGt(other.cumulativeVariance(), small * 2, "squares, not sums");
    }

    // --- the short side -----------------------------------------------------

    function test_depositMintsSharesAndLocksTheMinimum() public {
        _fund(1_000e18);
        assertGt(hook.balanceOf(seller), 0, "the seller holds shares");
        assertEq(hook.totalCollateral(), 1_000e18, "and the vault holds the collateral");
        assertEq(hook.freeCollateral(), 1_000e18, "all of it free while nothing is written");
    }

    function test_collateralCanBeWithdrawnWhileNothingIsWritten() public {
        _fund(1_000e18);
        uint256 shares = hook.balanceOf(seller);
        uint256 before = collateral.balanceOf(seller);

        vm.prank(seller);
        hook.withdraw(shares);

        assertGt(collateral.balanceOf(seller), before, "it came back");
    }

    // --- the long side ------------------------------------------------------

    function test_openingANoteLocksItsMaximumPayout() public {
        _fund(1_000e18);
        (uint256 premium, uint256 maxPayout) = hook.quote(100e18);
        assertGt(premium, 0, "a premium is charged");
        assertEq(maxPayout, 100e18, "the notional is the maximum payout");
        assertGt(maxPayout, premium, "and the note can pay more than it cost");

        vm.prank(buyer);
        hook.open(100e18, MIN_TERM);

        assertEq(hook.totalLocked(), maxPayout, "the whole maximum is locked");
        assertEq(hook.totalCollateral(), 1_000e18 + premium, "and the premium joined the vault");
    }

    function test_aNoteCannotBeWrittenWithoutCollateralToBackIt() public {
        _fund(1e18);
        vm.prank(buyer);
        vm.expectRevert();
        hook.open(1_000e18, MAX_TERM);
    }

    function test_aTermOutsideTheRangeIsRefused() public {
        _fund(1_000e18);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(VarianceSwapHook.TermOutOfRange.selector, MIN_TERM, MAX_TERM));
        hook.open(1e18, MIN_TERM - 1);
    }

    /// @dev The short side is committed for as long as the notes it is backing.
    function test_lockedCollateralCannotBeWithdrawn() public {
        _fund(100e18);
        vm.prank(buyer);
        hook.open(100e18, MIN_TERM);

        uint256 shares = hook.balanceOf(seller);
        vm.prank(seller);
        vm.expectRevert();
        hook.withdraw(shares);
    }

    // --- settlement ---------------------------------------------------------

    function test_aNoteCannotBeSettledEarly() public {
        _fund(1_000e18);
        vm.prank(buyer);
        uint256 note = hook.open(10e18, MIN_TERM);

        vm.expectRevert();
        hook.settle(note);
    }

    /// @dev A pool that stayed still owes the long side nothing, and the premium stays with the short side.
    function test_aQuietPoolPaysTheLongSideNothing() public {
        _fund(1_000e18);
        (uint256 premium,) = hook.quote(10e18);

        vm.prank(buyer);
        uint256 note = hook.open(10e18, MIN_TERM);

        vm.warp(block.timestamp + MIN_TERM + 1);
        uint256 before = collateral.balanceOf(buyer);
        hook.settle(note);

        assertEq(collateral.balanceOf(buyer), before, "nothing realised, nothing paid");
        assertEq(hook.totalCollateral(), 1_000e18 + premium, "the premium stayed with the vault");
        assertEq(hook.totalLocked(), 0, "and the collateral is free again");
    }

    /// @dev And a pool that moved a lot pays the long side, which is the whole trade.
    function test_aWildPoolPaysTheLongSide() public {
        _fund(5_000e18);
        vm.prank(buyer);
        uint256 note = hook.open(10e18, MIN_TERM);

        _shake(12, 20e18);
        vm.warp(block.timestamp + MIN_TERM);

        uint256 before = collateral.balanceOf(buyer);
        hook.settle(note);

        assertGt(collateral.balanceOf(buyer), before, "realised variance was paid");
        assertEq(hook.totalLocked(), 0, "and the lock released");
    }

    function test_thePayoutNeverExceedsWhatWasLocked() public {
        _fund(5_000e18);
        (, uint256 maxPayout) = hook.quote(10e18);

        vm.prank(buyer);
        uint256 note = hook.open(10e18, MIN_TERM);

        _shake(30, 40e18);
        vm.warp(block.timestamp + MIN_TERM);

        uint256 before = collateral.balanceOf(buyer);
        hook.settle(note);
        assertLe(collateral.balanceOf(buyer) - before, maxPayout, "capped at what was set aside for it");
    }

    function test_settlingAnUnknownNoteReverts() public {
        vm.expectRevert(VarianceSwapHook.NoSuchNote.selector);
        hook.settle(3);
    }

    function test_aNoteSettlesOnlyOnce() public {
        _fund(1_000e18);
        vm.prank(buyer);
        uint256 note = hook.open(10e18, MIN_TERM);
        vm.warp(block.timestamp + MIN_TERM + 1);

        hook.settle(note);
        vm.expectRevert(VarianceSwapHook.NoSuchNote.selector);
        hook.settle(note);
    }

    // --- invariants ---------------------------------------------------------

    /// @dev The vault must always be able to pay everything it has written. That is the whole solvency claim.
    function testFuzz_theVaultIsAlwaysSolvent(uint256 fund, uint256 notional, uint256 shakes) public {
        fund = bound(fund, 1e18, 5_000e18);
        notional = bound(notional, 1e15, 200e18);
        shakes = bound(shakes, 0, 20);

        _fund(fund);
        (, uint256 maxPayout) = hook.quote(notional);
        if (maxPayout > hook.freeCollateral() + 1) return; // more than the vault can back, correctly refused

        vm.prank(buyer);
        uint256 note = hook.open(notional, MIN_TERM);
        _shake(shakes, 10e18);
        vm.warp(block.timestamp + MIN_TERM);

        uint256 owed = hook.payoutIfSettledNow(note);
        assertLe(owed, hook.totalCollateral(), "the vault can always cover what it owes");
        hook.settle(note);
    }

    /// @dev Free collateral is never overstated, whatever has been written against the vault.
    function testFuzz_lockedCollateralIsNeverAvailable(uint256 fund, uint256 notional) public {
        fund = bound(fund, 100e18, 5_000e18);
        notional = bound(notional, 1e15, 100e18);

        _fund(fund);
        (, uint256 maxPayout) = hook.quote(notional);
        if (maxPayout > hook.freeCollateral()) return;

        vm.prank(buyer);
        hook.open(notional, MIN_TERM);

        assertEq(hook.freeCollateral(), hook.totalCollateral() - hook.totalLocked(), "the accounting agrees");
        assertGe(hook.totalCollateral(), hook.totalLocked(), "and never goes short of its obligations");
    }
}
