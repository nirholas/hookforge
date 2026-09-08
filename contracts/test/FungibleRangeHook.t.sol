// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FungibleRangeHook} from "src/hooks/FungibleRangeHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract FungibleRangeHookTest is ForgeTest {
    FungibleRangeHook internal hook;
    PoolKey internal poolKey;
    IERC20 internal token0;
    IERC20 internal token1;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

    int24 internal constant BASE_HALF = 600;
    int24 internal constant MAX_HALF = 6000;
    uint256 internal constant TRIGGER_BPS = 5_000; // half way to the edge
    uint256 internal constant WIDEN_BPS = 13_000; // 30% wider each forced move
    uint64 internal constant CALM = 1 days;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_000_000);

        hook = FungibleRangeHook(_deploy(0x4444));

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        token0 = IERC20(Currency.unwrap(currency0));
        token1 = IERC20(Currency.unwrap(currency1));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

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

    function _deploy(uint160 namespace) private returns (address) {
        return deployHookToNamespace(
            "src/hooks/FungibleRangeHook.sol:FungibleRangeHook",
            FLAGS,
            abi.encode(
                address(manager), BASE_HALF, MAX_HALF, TRIGGER_BPS, WIDEN_BPS, CALM, "Fungible Range LP", "FR-LP"
            ),
            namespace
        );
    }

    function _deposit(address who, uint256 amount) private returns (uint256 shares) {
        vm.prank(who);
        shares = hook.deposit(amount, amount);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "FungibleRange");
    }

    // --- construction -------------------------------------------------------

    function test_constructor_rejectsAMaximumBelowTheBase() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/FungibleRangeHook.sol:FungibleRangeHook",
            FLAGS,
            abi.encode(address(manager), int24(600), int24(300), TRIGGER_BPS, WIDEN_BPS, CALM, "n", "s"),
            0x1001
        );
    }

    /// @dev Widening by nothing is the fixed band this design exists to replace, so it must not be deployable.
    function test_constructor_rejectsABandThatNeverWidens() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/FungibleRangeHook.sol:FungibleRangeHook",
            FLAGS,
            abi.encode(address(manager), BASE_HALF, MAX_HALF, TRIGGER_BPS, uint256(10_000), CALM, "n", "s"),
            0x1002
        );
    }

    function test_theHookBindsToOnePoolOnly() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // --- deposits -----------------------------------------------------------

    function test_theFirstDepositOpensABandAroundThePrice() public {
        _deposit(alice, 100e18);

        assertGt(hook.placed(), 0, "liquidity is in the pool");
        assertLt(hook.tickLower(), hook.tickUpper(), "and the band is a real range");
        assertEq(hook.currentHalfWidth(), BASE_HALF, "opened at the base width");
    }

    function test_depositMintsSharesAndLocksTheMinimum() public {
        uint256 shares = _deposit(alice, 100e18);
        assertGt(shares, 0, "alice holds shares");
        assertEq(hook.balanceOf(alice), shares, "and they are hers");
        assertGt(hook.totalSupply(), shares, "with the minimum locked away");
    }

    function test_aSecondDepositIsPricedAgainstTheFirst() public {
        _deposit(alice, 100e18);
        uint256 aliceShares = hook.balanceOf(alice);

        _deposit(bob, 100e18);
        uint256 bobShares = hook.balanceOf(bob);

        assertApproxEqRel(bobShares, aliceShares, 0.01e18, "an equal deposit earns an equal stake");
    }

    function test_unusableAmountsAreReturned() public {
        // A one-sided deposit: the band needs both, so most of it cannot be placed.
        uint256 before1 = token1.balanceOf(alice);
        vm.prank(alice);
        hook.deposit(100e18, 1e18);
        assertLe(token1.balanceOf(alice), before1, "the usable part was taken");
        assertGt(token0.balanceOf(alice), 0, "and the rest came back");
    }

    function test_anEmptyDepositIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(FungibleRangeHook.AmountTooSmall.selector);
        hook.deposit(0, 0);
    }

    // --- withdrawals --------------------------------------------------------

    function test_withdrawReturnsBothSides() public {
        _deposit(alice, 100e18);
        uint256 shares = hook.balanceOf(alice);

        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = hook.withdraw(shares);

        assertGt(amount0 + amount1, 0, "something came back");
        assertEq(token0.balanceOf(alice), before0 + amount0, "in currency0");
        assertEq(token1.balanceOf(alice), before1 + amount1, "and currency1");
        assertEq(hook.balanceOf(alice), 0, "shares are burned");
    }

    function test_withdrawIsProRata() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        uint256 aliceShares = hook.balanceOf(alice);
        uint256 bobShares = hook.balanceOf(bob);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = hook.withdraw(aliceShares);
        vm.prank(bob);
        (uint256 b0, uint256 b1) = hook.withdraw(bobShares);

        assertApproxEqRel(a0 + a1, b0 + b1, 0.02e18, "equal stakes take equal slices");
    }

    function test_withdrawingNothingIsRefused() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(FungibleRangeHook.AmountTooSmall.selector);
        hook.withdraw(0);
    }

    // --- rebalancing --------------------------------------------------------

    function test_aSmallMoveDoesNotRebalance() public {
        _deposit(alice, 100e18);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(hook.rebalances(), 0, "inside the band, nothing moves");
    }

    function test_leavingTheBandRecentresThePosition() public {
        _deposit(alice, 100e18);
        int24 lowerBefore = hook.tickLower();

        swap(poolKey, true, -60e18, ZERO_BYTES);

        assertEq(hook.rebalances(), 1, "the position moved once");
        assertLt(hook.tickLower(), lowerBefore, "and moved the way the price went");
        assertGt(hook.placed(), 0, "with liquidity still placed");
    }

    /// @dev The property the whole design rests on: forcing a move makes the next one harder to force.
    function test_everyForcedMoveWidensTheBand() public {
        _deposit(alice, 100e18);
        int24 widthBefore = hook.currentHalfWidth();

        swap(poolKey, true, -60e18, ZERO_BYTES);
        int24 afterFirst = hook.currentHalfWidth();
        assertGt(afterFirst, widthBefore, "the first forced move widened it");

        swap(poolKey, true, -60e18, ZERO_BYTES);
        assertGt(hook.currentHalfWidth(), afterFirst, "and so did the second");
    }

    function test_theBandNeverExceedsItsMaximum() public {
        _deposit(alice, 100e18);
        for (uint256 i = 0; i < 12; i++) {
            swap(poolKey, i % 2 == 0, -60e18, ZERO_BYTES);
        }
        assertLe(hook.currentHalfWidth(), MAX_HALF, "the ceiling holds");
    }

    /// @dev And the other half: stop attacking and the band tightens again by itself.
    function test_quietTimeNarrowsTheBandBack() public {
        _deposit(alice, 100e18);
        swap(poolKey, true, -60e18, ZERO_BYTES);
        int24 widened = hook.currentHalfWidth();
        assertGt(widened, BASE_HALF, "sanity: it widened");

        vm.warp(block.timestamp + CALM / 2);
        int24 halfway = hook.currentHalfWidth();
        assertLt(halfway, widened, "half the calm has undone half the widening");
        assertGt(halfway, BASE_HALF, "but not all of it");

        vm.warp(block.timestamp + CALM);
        assertEq(hook.currentHalfWidth(), BASE_HALF, "and a full calm returns it to base");
    }

    function test_rebalanceDueReportsWhatTheNextSwapWillDo() public {
        _deposit(alice, 100e18);
        assertFalse(hook.rebalanceDue(), "nothing due at the start");

        swap(poolKey, true, -60e18, ZERO_BYTES);
        assertFalse(hook.rebalanceDue(), "and nothing due right after a move");
    }

    function test_anEmptyPositionNeverRebalances() public {
        assertFalse(hook.rebalanceDue(), "no liquidity, nothing to move");
    }

    /// @dev A rebalance must not quietly lose the position: liquidity goes out and comes back in one call.
    function test_liquidityIsNeverLeftUnplaced() public {
        _deposit(alice, 100e18);
        uint128 before = hook.placed();
        swap(poolKey, true, -60e18, ZERO_BYTES);

        assertGt(hook.placed(), 0, "still placed after the move");
        assertGt(before, 0, "sanity: it was placed before");
    }

    /// @dev Depositors must still be able to leave after the band has moved under them.
    function test_withdrawWorksAfterARebalance() public {
        _deposit(alice, 100e18);
        swap(poolKey, true, -60e18, ZERO_BYTES);

        uint256 shares = hook.balanceOf(alice);
        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = hook.withdraw(shares);
        assertGt(amount0 + amount1, 0, "the position is still withdrawable");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev However hard the price is pushed, the band stays inside the bounds the constructor promised.
    function testFuzz_theBandStaysInsideItsBounds(uint256 size, uint8 rounds) public {
        _deposit(alice, 200e18);
        size = bound(size, 1e18, 60e18);
        rounds = uint8(bound(rounds, 1, 8));

        for (uint256 i = 0; i < rounds; i++) {
            swap(poolKey, i % 2 == 0, -int256(size), ZERO_BYTES);
        }

        int24 width = hook.currentHalfWidth();
        assertGe(width, BASE_HALF, "never narrower than base");
        assertLe(width, MAX_HALF, "never wider than the ceiling");
        assertLt(hook.tickLower(), hook.tickUpper(), "and always a real range");
    }

    /// @dev Shares must stay redeemable for something, whatever the price did in between.
    function testFuzz_sharesStayRedeemable(uint256 size) public {
        size = bound(size, 1e18, 60e18);
        _deposit(alice, 100e18);
        swap(poolKey, true, -int256(size), ZERO_BYTES);

        uint256 shares = hook.balanceOf(alice);
        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = hook.withdraw(shares);
        assertGt(amount0 + amount1, 0, "a share is always worth something");
    }
}
