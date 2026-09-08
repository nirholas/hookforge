// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ImpactSplitHook} from "src/hooks/ImpactSplitHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract ImpactSplitHookTest is ForgeTest {
    ImpactSplitHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 internal constant MAX_IMPACT = 50_000; // 5% at the extreme
    uint32 internal constant HALF_POINT = 200; // half the charge at a 200 tick move
    uint32 internal constant WINDOW = 1 hours;
    uint32 internal constant MIN_TICKS = 5;

    address internal alice = address(0xA11CE);

    function setUp() public {
        setUpForge();
        vm.warp(1_000_000);

        hook = ImpactSplitHook(
            deployHookTo("src/hooks/ImpactSplitHook.sol:ImpactSplitHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(
            poolKey,
            ImpactSplitHook.Config({
                maxImpactFee: MAX_IMPACT,
                halfPointTicks: HALF_POINT,
                windowSeconds: WINDOW,
                minTicks: MIN_TICKS
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-24000, 24000, 5e19, bytes32(0)), ZERO_BYTES
        );
    }

    function _escrow(uint256 index) private view returns (ImpactSplitHook.Escrow memory e) {
        (address payer, Currency currency, uint128 amount, int24 tickBefore, int24 tickAfter, uint64 settleAt) =
            hook.escrowOf(poolId, index);
        e = ImpactSplitHook.Escrow(payer, currency, amount, tickBefore, tickAfter, settleAt);
    }

    /// @dev Swaps naming alice as the payer, which is how a router-carried swap attributes its escrow.
    function _swapAs(address who, bool zeroForOne, int256 amount) private {
        swap(poolKey, zeroForOne, amount, abi.encode(who));
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ImpactSplit");
    }

    // --- configuration ------------------------------------------------------

    function test_configure_rejectsAZeroWindow() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(ImpactSplitHook.InvalidConfig.selector);
        hook.configure(
            other,
            ImpactSplitHook.Config({
                maxImpactFee: MAX_IMPACT,
                halfPointTicks: HALF_POINT,
                windowSeconds: 0,
                minTicks: MIN_TICKS
            })
        );
    }

    function test_anUnconfiguredPoolCannotBeInitialized() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // --- charging -----------------------------------------------------------

    function test_aSwapThatMovesNothingIsNotCharged() public {
        _swapAs(alice, true, -1e13);
        assertEq(hook.escrowCount(poolId), 0, "noise is not impact");
    }

    function test_aSwapThatMovesThePriceIsEscrowed() public {
        _swapAs(alice, true, -5e18);

        assertEq(hook.escrowCount(poolId), 1, "one escrow opened");
        ImpactSplitHook.Escrow memory e = _escrow(0);
        assertEq(e.payer, alice, "attributed to whoever the swap named");
        assertGt(e.amount, 0, "and holding a real charge");
        assertLt(e.tickAfter, e.tickBefore, "the swap moved the price down");
    }

    function test_theChargeGrowsWithTheMove() public view {
        assertEq(hook.impactFeeFor(poolKey, MIN_TICKS - 1), 0, "below the noise floor, nothing");
        assertGt(hook.impactFeeFor(poolKey, 100), hook.impactFeeFor(poolKey, MIN_TICKS), "and rising from there");
        assertGt(hook.impactFeeFor(poolKey, 400), hook.impactFeeFor(poolKey, 100), "and still rising");
    }

    function test_theChargeIsHalfTheCapAtTheHalfPoint() public view {
        assertEq(hook.impactFeeFor(poolKey, HALF_POINT), MAX_IMPACT / 2, "the half point means what it says");
    }

    function test_theChargeApproachesTheCapWithoutReachingIt() public view {
        assertLt(hook.impactFeeFor(poolKey, 1_000_000), MAX_IMPACT, "never the whole cap");
        assertGt(hook.impactFeeFor(poolKey, 1_000_000), (MAX_IMPACT * 99) / 100, "but arbitrarily close");
    }

    function test_aBiggerMoveIsChargedMore() public {
        _swapAs(alice, true, -2e18);
        uint128 small = _escrow(0).amount;

        _swapAs(alice, true, -40e18);
        uint128 large = _escrow(1).amount;

        assertGt(large, small, "a move ten times the size is charged more, not the same");
    }

    function test_theChargeIsCapped() public {
        _swapAs(alice, true, -200e18);
        ImpactSplitHook.Escrow memory e = _escrow(0);
        assertGt(e.amount, 0, "charged something");
        assertLe(e.settleAt, block.timestamp + WINDOW, "and dated by the configured window");
    }

    // --- settlement ---------------------------------------------------------

    function test_anEscrowCannotBeSettledEarly() public {
        _swapAs(alice, true, -5e18);
        uint256 settleAt = _escrow(0).settleAt;
        vm.expectRevert(abi.encodeWithSelector(ImpactSplitHook.TooSoon.selector, settleAt));
        hook.settle(poolKey, 0);
    }

    function test_settlingAnUnknownEscrowReverts() public {
        vm.expectRevert(ImpactSplitHook.NoSuchEscrow.selector);
        hook.settle(poolKey, 7);
    }

    /// @dev A move that held is information, and the whole charge belongs to the providers who wore it.
    function test_aMoveThatHoldsPaysTheProviders() public {
        _swapAs(alice, true, -20e18);
        assertEq(hook.survivedBps(poolKey, 0), 10_000, "nothing has come back");

        vm.warp(block.timestamp + WINDOW);
        hook.settle(poolKey, 0);

        assertEq(hook.refundOf(alice, currency0), 0, "no refund in currency0");
        assertEq(hook.refundOf(alice, currency1), 0, "nor in currency1");
        assertEq(_escrow(0).payer, address(0), "and the escrow is closed");
    }

    /// @dev And a move that came all the way back was only ever the cost of demanding liquidity. Refund it.
    function test_aMoveThatFullyRevertsIsRefunded() public {
        _swapAs(alice, true, -20e18);
        uint128 charged = _escrow(0).amount;
        assertGt(charged, 0, "sanity: something was charged");

        // Push the price back past where it started.
        swap(poolKey, false, -40e18, ZERO_BYTES);
        assertEq(hook.survivedBps(poolKey, 0), 0, "none of the move survived");

        vm.warp(block.timestamp + WINDOW);
        hook.settle(poolKey, 0);

        uint256 refunded = hook.refundOf(alice, currency0) + hook.refundOf(alice, currency1);
        assertEq(refunded, charged, "the whole charge came back");
    }

    /// @dev The interesting case: a move that partly decayed splits, and the two halves add up.
    function test_aPartialReversionSplitsTheCharge() public {
        _swapAs(alice, true, -20e18);
        uint128 charged = _escrow(0).amount;

        swap(poolKey, false, -8e18, ZERO_BYTES);
        uint256 survived = hook.survivedBps(poolKey, 0);
        assertGt(survived, 0, "some of the move held");
        assertLt(survived, 10_000, "and some of it decayed");

        vm.warp(block.timestamp + WINDOW);
        hook.settle(poolKey, 0);

        uint256 refunded = hook.refundOf(alice, currency0) + hook.refundOf(alice, currency1);
        assertGt(refunded, 0, "the decayed part came back");
        assertLt(refunded, charged, "the surviving part did not");
        assertEq(refunded, uint256(charged) - (uint256(charged) * survived) / 10_000, "the split is exact");
    }

    function test_aMoveThatCarriedFurtherIsNotOwedMore() public {
        _swapAs(alice, true, -10e18);
        swap(poolKey, true, -40e18, ZERO_BYTES);
        assertEq(hook.survivedBps(poolKey, 0), 10_000, "capped at the whole charge, never above it");
    }

    // --- withdrawal ---------------------------------------------------------

    function test_refundsAreWithdrawableAsRealTokens() public {
        _swapAs(alice, true, -20e18);
        swap(poolKey, false, -40e18, ZERO_BYTES);
        vm.warp(block.timestamp + WINDOW);
        hook.settle(poolKey, 0);

        uint256 owed0 = hook.refundOf(alice, currency0);
        uint256 owed1 = hook.refundOf(alice, currency1);
        assertGt(owed0 + owed1, 0, "sanity: there is a refund");

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        vm.prank(alice);
        hook.withdraw(poolKey);

        assertEq(token0.balanceOf(alice), before0 + owed0, "paid out in currency0");
        assertEq(token1.balanceOf(alice), before1 + owed1, "and currency1");
        assertEq(hook.refundOf(alice, currency0) + hook.refundOf(alice, currency1), 0, "ledger cleared");
    }

    function test_withdrawingNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(ImpactSplitHook.NothingToWithdraw.selector);
        hook.withdraw(poolKey);
    }

    // --- invariants ---------------------------------------------------------

    /// @dev The two halves of a settled escrow must always add back up to what was charged.
    function testFuzz_theSplitIsConservative(uint256 push, uint256 pull) public {
        push = bound(push, 2e18, 50e18);
        pull = bound(pull, 1e17, 60e18);

        _swapAs(alice, true, -int256(push));
        if (hook.escrowCount(poolId) == 0) return; // the move was below the noise floor
        uint128 charged = _escrow(0).amount;

        swap(poolKey, false, -int256(pull), ZERO_BYTES);
        uint256 survived = hook.survivedBps(poolKey, 0);

        vm.warp(block.timestamp + WINDOW);
        hook.settle(poolKey, 0);

        uint256 refunded = hook.refundOf(alice, currency0) + hook.refundOf(alice, currency1);
        uint256 toProviders = (uint256(charged) * survived) / 10_000;
        assertEq(refunded + toProviders, charged, "nothing is created and nothing is lost");
    }

    /// @dev The surviving share is always a real fraction, whatever the price did.
    function testFuzz_survivalIsAlwaysAFraction(uint256 push, uint256 pull, bool back) public {
        push = bound(push, 2e18, 50e18);
        pull = bound(pull, 1e17, 60e18);

        _swapAs(alice, true, -int256(push));
        if (hook.escrowCount(poolId) == 0) return;

        swap(poolKey, back, -int256(pull), ZERO_BYTES);
        assertLe(hook.survivedBps(poolKey, 0), 10_000, "never more than all of it");
    }
}
