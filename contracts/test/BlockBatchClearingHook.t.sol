// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BlockBatchClearingHook} from "src/hooks/BlockBatchClearingHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract BlockBatchClearingHookTest is ForgeTest {
    BlockBatchClearingHook internal hook;
    PoolKey internal poolKey;
    IERC20 internal token0;
    IERC20 internal token1;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint256 internal constant FEE_BPS = 30;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.roll(1000);

        hook = BlockBatchClearingHook(
            deployHookTo(
                "src/hooks/BlockBatchClearingHook.sol:BlockBatchClearingHook",
                FLAGS,
                abi.encode(address(manager), FEE_BPS, "Batch LP", "BATCH-LP")
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        token0 = IERC20(Currency.unwrap(currency0));
        token1 = IERC20(Currency.unwrap(currency1));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(1_000e18, 1_000e18);
    }

    /// @dev Places an order attributed to `who`, which is how a router-carried swap names its owner.
    function _order(address who, bool zeroForOne, uint256 amountIn) private {
        swap(poolKey, zeroForOne, -int256(amountIn), abi.encode(who));
    }

    function _batch(uint256 index) private view returns (BlockBatchClearingHook.Batch memory b) {
        (uint64 blockNumber, uint128 in0, uint128 in1, uint256 price, bool cleared) = hook.batchOf(index);
        b = BlockBatchClearingHook.Batch(blockNumber, in0, in1, price, cleared);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "BlockBatchClearing");
    }

    // --- structure ----------------------------------------------------------

    function test_thePoolsOwnLiquidityPathIsClosed() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(-60, 60, 1e18, bytes32(0)), ZERO_BYTES);
    }

    function test_exactOutputIsRefused() public {
        vm.expectRevert();
        swap(poolKey, true, 1e18, ZERO_BYTES);
    }

    function test_aSwapReturnsNothingImmediately() public {
        uint256 before = token1.balanceOf(address(this));
        _order(address(this), true, 10e18);
        assertEq(token1.balanceOf(address(this)), before, "a batch order pays out later, not now");
    }

    // --- batching -----------------------------------------------------------

    function test_ordersInOneBlockJoinOneBatch() public {
        _order(alice, true, 10e18);
        _order(bob, true, 20e18);

        assertEq(hook.batchCount(), 1, "one batch");
        assertEq(hook.orderCount(0), 2, "holding both orders");
        assertEq(_batch(0).in0, 30e18, "with their inputs summed");
    }

    function test_aNewBlockOpensANewBatch() public {
        _order(alice, true, 10e18);
        vm.roll(block.number + 1);
        _order(bob, true, 10e18);

        assertEq(hook.batchCount(), 2, "a second batch opened");
        assertTrue(_batch(0).cleared, "and the first cleared on the way");
    }

    function test_aBatchIsNotClearableInItsOwnBlock() public {
        _order(alice, true, 10e18);
        assertFalse(hook.clearable(), "still taking orders");
        hook.clear();
        assertFalse(_batch(0).cleared, "and clearing early does nothing");
    }

    function test_anybodyCanClearAQuietPool() public {
        _order(alice, true, 10e18);
        vm.roll(block.number + 1);

        assertTrue(hook.clearable(), "ready once the block has passed");
        vm.prank(bob);
        hook.clear();
        assertTrue(_batch(0).cleared, "and anyone may do it");
    }

    // --- the uniform price --------------------------------------------------

    /// @dev The property the whole design exists for.
    function test_everybodyInABatchGetsTheSamePrice() public {
        _order(alice, true, 10e18);
        _order(bob, true, 30e18);
        vm.roll(block.number + 1);
        hook.clear();

        uint256 aliceOut = hook.owed(0, 0);
        uint256 bobOut = hook.owed(0, 1);

        // Three times the input must buy exactly three times the output, to within a wei of rounding.
        assertApproxEqAbs(bobOut, aliceOut * 3, 3, "size bought no advantage and no penalty");
    }

    function test_orderPositionInTheBlockBuysNothing() public {
        _order(alice, true, 10e18);
        _order(bob, true, 10e18);
        vm.roll(block.number + 1);
        hook.clear();

        assertApproxEqAbs(hook.owed(0, 0), hook.owed(0, 1), 2, "first and last fill identically");
    }

    /// @dev Matched flow never touches the curve, which is the efficiency a continuous AMM cannot offer.
    function test_evenlyMatchedFlowClearsAtSpot() public {
        // A balanced pool prices at one, and a batch with equal value on both sides should clear there.
        _order(alice, true, 50e18);
        _order(bob, false, 50e18);
        vm.roll(block.number + 1);
        hook.clear();

        assertApproxEqRel(_batch(0).price, 1e18, 0.0001e18, "no slippage at all on matched flow");
    }

    function test_matchedFlowBeatsTheSameTradesSeparately() public {
        // Both directions in one batch.
        _order(alice, true, 100e18);
        _order(bob, false, 100e18);
        vm.roll(block.number + 1);
        hook.clear();
        uint256 matchedOut = hook.owed(0, 0);

        // The same buy alone, against the same reserves, in a later batch.
        _order(alice, true, 100e18);
        vm.roll(block.number + 1);
        hook.clear();
        uint256 aloneOut = hook.owed(1, 0);

        assertGt(matchedOut, aloneOut, "being matched against a seller is worth more than facing the curve");
    }

    function test_anImbalancedBatchMovesThePrice() public {
        _order(alice, true, 200e18);
        vm.roll(block.number + 1);
        hook.clear();

        assertLt(_batch(0).price, 1e18, "a one-sided batch pays the curve, as it should");
    }

    // --- collecting ---------------------------------------------------------

    function test_anOrderCollectsRealTokens() public {
        _order(alice, true, 10e18);
        vm.roll(block.number + 1);
        hook.clear();

        uint256 due = hook.owed(0, 0);
        assertGt(due, 0, "sanity: there is something to collect");

        uint256 before = token1.balanceOf(alice);
        hook.collect(0, 0);
        assertEq(token1.balanceOf(alice), before + due, "paid out as tokens to the order's owner");
    }

    function test_anOrderCannotCollectTwice() public {
        _order(alice, true, 10e18);
        vm.roll(block.number + 1);
        hook.clear();

        hook.collect(0, 0);
        vm.expectRevert(BlockBatchClearingHook.NothingToCollect.selector);
        hook.collect(0, 0);
    }

    function test_anUnclearedOrderCannotCollect() public {
        _order(alice, true, 10e18);
        vm.expectRevert(BlockBatchClearingHook.NotCleared.selector);
        hook.collect(0, 0);
    }

    function test_bothDirectionsCollectTheirOwnCurrency() public {
        _order(alice, true, 20e18);
        _order(bob, false, 20e18);
        vm.roll(block.number + 1);
        hook.clear();

        uint256 aliceBefore = token1.balanceOf(alice);
        uint256 bobBefore = token0.balanceOf(bob);
        hook.collect(0, 0);
        hook.collect(0, 1);

        assertGt(token1.balanceOf(alice) - aliceBefore, 0, "the buyer of currency1 got currency1");
        assertGt(token0.balanceOf(bob) - bobBefore, 0, "and the buyer of currency0 got currency0");
    }

    // --- liquidity ----------------------------------------------------------

    function test_depositMintsSharesAndLocksTheMinimum() public view {
        assertGt(hook.balanceOf(address(this)), 0, "the depositor holds shares");
        assertGt(hook.totalSupply(), hook.balanceOf(address(this)), "with the minimum locked away");
    }

    function test_withdrawReturnsBothSides() public {
        uint256 shares = hook.balanceOf(address(this)) / 2;
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));

        hook.withdraw(shares);

        assertGt(token0.balanceOf(address(this)), before0, "currency0 came back");
        assertGt(token1.balanceOf(address(this)), before1, "and currency1");
    }

    function test_theFeeStaysWithTheProviders() public {
        uint256 before = hook.reserve0() + hook.reserve1();
        _order(alice, true, 100e18);
        vm.roll(block.number + 1);
        hook.clear();

        // Everything paid in stays in the reserves except what the clearing paid out, and the fee is the difference.
        assertGt(hook.reserve0() + hook.reserve1(), before, "the reserves grew by the fee");
    }

    /**
     * @dev A one-wei order must not be able to stop a batch clearing.
     *
     * Found by the solvency fuzz below. The price solver scales its inputs down to keep the discriminant inside a
     * uint256, and a side small enough to round to zero under that scaling used to revert, which handed anybody a
     * way to freeze everyone else's funds in an uncleared batch for the price of one wei.
     */
    function test_aDustOrderCannotFreezeABatch() public {
        _order(alice, true, 1000); // one thousand wei against reserves of a thousand tokens
        _order(bob, false, 100e18);
        vm.roll(block.number + 1);

        hook.clear();
        assertTrue(_batch(0).cleared, "the batch cleared despite the dust");
        assertGt(_batch(0).price, 0, "at a real price");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev The clearing price must always be solvent: neither side can be paid more than the pool holds.
    function testFuzz_clearingIsAlwaysSolvent(uint256 buy, uint256 sell) public {
        buy = bound(buy, 0, 500e18);
        sell = bound(sell, 0, 500e18);
        if (buy == 0 && sell == 0) return;

        if (buy > 0) _order(alice, true, buy);
        if (sell > 0) _order(bob, false, sell);
        vm.roll(block.number + 1);
        hook.clear();

        assertTrue(_batch(0).cleared, "it cleared");
        assertGt(hook.reserve0(), 0, "with currency0 left");
        assertGt(hook.reserve1(), 0, "and currency1 left");
    }

    /// @dev Two orders the same way must always be filled in exact proportion to what they paid.
    function testFuzz_fillsAreStrictlyProportional(uint256 a, uint256 b) public {
        a = bound(a, 1e16, 200e18);
        b = bound(b, 1e16, 200e18);

        _order(alice, true, a);
        _order(bob, true, b);
        vm.roll(block.number + 1);
        hook.clear();

        uint256 outA = hook.owed(0, 0);
        uint256 outB = hook.owed(0, 1);
        // Cross-multiplied, so the comparison holds without dividing and losing the remainder.
        assertApproxEqRel(outA * b, outB * a, 0.0001e18, "the same price for both, whatever the sizes");
    }
}
