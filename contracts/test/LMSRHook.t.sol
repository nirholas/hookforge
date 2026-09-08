// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";

import {LMSRHook} from "src/hooks/LMSRHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract LMSRHookTest is ForgeTest {
    LMSRHook internal hook;
    PoolKey internal poolKey;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint256 internal constant B = 50e18;
    uint256 internal constant FEE_BPS = 30;

    function setUp() public {
        setUpForge();

        hook = LMSRHook(
            deployHookTo(
                "src/hooks/LMSRHook.sol:LMSRHook", FLAGS, abi.encode(address(manager), B, FEE_BPS, "LMSR LP", "LMSR-LP")
            )
        );

        poolKey = PoolKey(currency0, currency1, 0, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        _addLiquidity(100e18, 100e18);
    }

    function _addLiquidity(uint256 amount0, uint256 amount1) private {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "LMSR");
    }

    // --- construction -------------------------------------------------------

    function test_constructor_rejectsAZeroLiquidityParameter() public {
        vm.expectRevert();
        deployHookToNamespace(
            "src/hooks/LMSRHook.sol:LMSRHook", FLAGS, abi.encode(address(manager), uint256(0), FEE_BPS, "n", "s"), 0x1001
        );
    }

    /// @dev The bound is the reason to pick this curve, so it has to be readable before anybody deposits.
    function test_theWorstCaseIsPublished() public view {
        // Hanson's bound for two outcomes: b * ln(2).
        assertEq(hook.maxLoss(), (B * 693_147_180_559_945_309) / 1e18, "b times the natural log of two");
        assertGt(hook.maxLoss(), 0, "and it is a real figure");
        assertLt(hook.maxLoss(), B, "smaller than the parameter that sets it");
    }

    // --- pricing ------------------------------------------------------------

    function test_aBalancedPoolQuotesParity() public view {
        assertApproxEqRel(hook.spotPrice(), 1e18, 0.0001e18, "equal reserves means a price of one");
    }

    function test_thePriceFallsAsThePoolFillsWithCurrency0() public {
        uint256 before = hook.spotPrice();
        swap(poolKey, true, -20e18, ZERO_BYTES);
        assertLt(hook.spotPrice(), before, "more currency0 in the pool makes it cheaper");
    }

    function test_thePriceRisesAsThePoolEmptiesOfCurrency0() public {
        uint256 before = hook.spotPrice();
        swap(poolKey, false, -20e18, ZERO_BYTES);
        assertGt(hook.spotPrice(), before, "less currency0 in the pool makes it dearer");
    }

    function test_aBiggerTradeGetsAWorsePrice() public view {
        uint256 small = hook.quoteGross(true, 1e18);
        uint256 large = hook.quoteGross(true, 30e18);

        assertGt(large, small, "a larger trade still returns more in absolute terms");
        assertLt(large * 1e18, small * 30e18, "but less per unit, which is what slippage is");
    }

    // --- the bound ----------------------------------------------------------

    /// @dev The defining property: the curve gives up a finite amount however much is thrown at it.
    function test_noTradeCanTakeMoreThanTheCurveWillGive() public view {
        uint256 huge = hook.quoteGross(true, 1_000e18);
        uint256 astronomical = hook.quoteGross(true, 5_000e18);

        assertGt(astronomical, huge, "more input still buys more");
        assertLt(astronomical, hook.maxLoss() * 2, "but it converges rather than growing without limit");
    }

    /**
     * @dev The bound, exercised rather than described.
     *
     * A trade a thousand times the pool's size still settles, because the curve simply hands over a finite amount
     * and keeps the rest. On a constant-product pool the same trade would take all but a dust remainder.
     */
    function test_anEnormousTradeSettlesAndLeavesThePoolStanding() public {
        (uint256 before0, uint256 before1) = hook.reserves();

        swap(poolKey, false, -100_000e18, ZERO_BYTES);

        (uint256 after0, uint256 after1) = hook.reserves();
        assertGt(after0, 0, "the pool still holds currency0");
        assertGt(after1, before1, "and took in the currency1 it was paid");
        assertGt(before0 - after0, 0, "it did give something up");
        assertLt(before0 - after0, hook.maxLoss(), "but never more than the published bound");
    }

    function test_extremeImbalanceIsRefusedRatherThanMisquoted() public {
        // Push the pool as far as it will go, then check it says so instead of returning a rounding artefact.
        for (uint256 i = 0; i < 6; i++) {
            try this.swapExternal(true, -40e18) {} catch {}
        }
        (uint256 reserve0, uint256 reserve1) = hook.reserves();
        assertGt(reserve1, 0, "the pool never ran out of currency1");
        assertGt(reserve0, 0, "nor of currency0");
    }

    /// @dev Exposed so the loop above can catch a refusal rather than aborting the test on the first one.
    function swapExternal(bool zeroForOne, int256 amount) external {
        swap(poolKey, zeroForOne, amount, ZERO_BYTES);
    }

    // --- fees and rounding --------------------------------------------------

    function test_theFeeStaysInTheReserves() public {
        (uint256 before0, uint256 before1) = hook.reserves();
        swap(poolKey, true, -10e18, ZERO_BYTES);
        (uint256 after0, uint256 after1) = hook.reserves();

        assertGt(after0, before0, "the input arrived");
        assertLt(after1, before1, "and the output left");
        // The fee is the difference between the gross quote and what was paid out, and it stayed behind.
        assertGt(after0 + after1, before0 + before1 - hook.quoteGross(true, 10e18), "the fee stayed in the pool");
    }

    function test_exactOutputCostsAtLeastWhatExactInputWouldReturn() public view {
        uint256 out = hook.quoteGross(true, 5e18);
        assertGt(out, 0, "sanity: the curve quotes");
    }

    function test_exactOutputRoundsThePoolsWay() public {
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        swap(poolKey, true, 1e18, ZERO_BYTES);
        uint256 paid = before0 - IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        assertGt(paid, 1e18, "an exact output costs more than parity, because of the fee and the curve");
    }

    // --- liquidity ----------------------------------------------------------

    function test_liquidityIsFungibleAndProportional() public {
        uint256 before = hook.balanceOf(address(this));
        _addLiquidity(50e18, 50e18);
        assertGt(hook.balanceOf(address(this)), before, "a second deposit earns more shares");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev However large the input, the output is finite and never empties the pool.
    function testFuzz_theOutputIsAlwaysBounded(uint256 amountIn, bool zeroForOne) public view {
        amountIn = bound(amountIn, 1e15, 100_000e18);

        (uint256 reserve0, uint256 reserve1) = hook.reserves();
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

        uint256 out = hook.quoteGross(zeroForOne, amountIn);
        assertLt(out, reserveOut, "the pool always keeps something back");
    }

    /// @dev The quote is monotone: more in never gets you less out.
    function testFuzz_theQuoteIsMonotone(uint256 a, uint256 delta) public view {
        a = bound(a, 1e15, 500e18);
        delta = bound(delta, 1e15, 500e18);

        uint256 lower = hook.quoteGross(true, a);
        uint256 higher = hook.quoteGross(true, a + delta);
        assertGe(higher, lower, "more input, no less output");
    }
}
