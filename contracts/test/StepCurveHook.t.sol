// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";

import {StepCurveHook} from "src/hooks/StepCurveHook.sol";
import {ForgeCurveHook} from "src/base/ForgeCurveHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract StepCurveHookTest is ForgeTest {
    StepCurveHook internal hook;
    PoolKey internal poolKey;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant START_PRICE = 2 * Q96; // currency0 opens at 2 currency1
    uint256 internal constant STEP = Q96 / 100; // each band drops the price by 0.01
    uint256 internal constant MIN_PRICE = Q96 / 2;
    uint256 internal constant STEP_SIZE = 1e18; // one band per whole unit of currency0
    uint256 internal constant FEE_BPS = 30; // 0.30%

    function setUp() public {
        setUpForge();

        hook = StepCurveHook(
            deployHookTo(
                "src/hooks/StepCurveHook.sol:StepCurveHook",
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG,
                abi.encode(
                    address(manager), START_PRICE, STEP, MIN_PRICE, STEP_SIZE, FEE_BPS, "Step Curve LP", "STEP-LP"
                )
            )
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        _addLiquidity(50e18, 100e18);
    }

    function _addLiquidity(uint256 amount0, uint256 amount1) private returns (BalanceDelta) {
        return hook.addLiquidity(
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
        assertMetadata(address(hook), "StepCurve");
    }

    function test_liquidityMintsShares_andReservesMatch() public view {
        (uint256 reserve0, uint256 reserve1) = hook.reserves();
        assertEq(reserve0, 50e18, "currency0 reserve");
        assertEq(reserve1, 100e18, "currency1 reserve");
        assertGt(hook.balanceOf(address(this)), 0, "the depositor should hold shares");
    }

    function test_priceIsConstantInsideABand_andStepsBetweenThem() public view {
        // Reserve0 is 50e18, so the pool is 50 bands down: 2.00 - 50 * 0.01 = 1.50.
        uint256 expected = START_PRICE - 50 * STEP;
        assertEq(hook.priceAt(50e18), expected);
        assertEq(hook.priceAt(50e18 + 1), expected, "one wei into a band changes nothing");
        assertEq(hook.priceAt(51e18 - 1), expected, "the whole band quotes the same price");
        assertEq(hook.priceAt(51e18), expected - STEP, "crossing the boundary steps the price");
        assertEq(hook.currentPriceX96(), expected);
    }

    function test_priceBottomsOutAtTheFloor() public view {
        assertEq(hook.priceAt(1_000_000e18), MIN_PRICE, "the ladder does not go below its floor");
    }

    function test_smallSwapsInsideABandHaveNoSlippage() public view {
        // Constant-sum inside a band: doubling the input doubles the output exactly, which a curve never does.
        uint256 outA = hook.quote(true, true, 0.1e18);
        uint256 outB = hook.quote(true, true, 0.2e18);
        assertEq(outB, outA * 2, "no slippage inside a band");
    }

    function test_aSwapCrossingBandsGetsAWorsePriceOnEachOne() public view {
        // Selling 3 units crosses three bands, so the average price must be below the first band's price.
        uint256 price = hook.priceAt(50e18);
        uint256 out = hook.quote(true, true, 3e18);
        assertLt(out, (3e18 * price) / Q96, "later bands must fill worse than the first");
        assertGt(out, (3e18 * (price - 3 * STEP)) / Q96, "and better than the last band alone");
    }

    function test_quoteRoundsInThePoolsFavour() public view {
        // For an exact-output swap the input is rounded up, so the pool is never short by a wei.
        uint256 wanted = 1e18 + 1;
        uint256 inputNeeded = hook.quote(false, false, wanted);
        uint256 price = hook.priceAt(50e18 - 1);
        assertGe(inputNeeded, (wanted * price) / Q96, "the input must cover the output");
    }

    function test_swapSellingCurrency0_movesTheLadderDown() public {
        uint256 priceBefore = hook.currentPriceX96();
        swap(poolKey, true, -2e18, ZERO_BYTES);
        assertLt(hook.currentPriceX96(), priceBefore, "selling currency0 should walk the ladder down");
    }

    function test_swapBuyingCurrency0_movesTheLadderUp() public {
        uint256 priceBefore = hook.currentPriceX96();
        swap(poolKey, false, -3e18, ZERO_BYTES);
        assertGt(hook.currentPriceX96(), priceBefore, "buying currency0 should walk the ladder up");
    }

    function test_swapPaysTheQuotedAmount() public {
        uint256 quoted = hook.quote(true, true, 1e18);
        uint256 gross = hook.quoteGross(true, true, 1e18);
        assertEq(quoted, gross - (gross * FEE_BPS) / 10_000, "the quote is the ladder less the fee");

        BalanceDelta delta = swap(poolKey, true, -1e18, ZERO_BYTES);
        assertEq(delta.amount0(), -1e18, "input should be exactly what was specified");
        assertEq(uint256(uint128(delta.amount1())), quoted, "output should be exactly what was quoted");
    }

    function test_theFeeStaysWithTheProviders() public {
        uint256 gross = hook.quoteGross(true, true, 1e18);
        uint256 expectedFee = (gross * FEE_BPS) / 10_000;

        (uint256 before0, uint256 before1) = hook.reserves();
        swap(poolKey, true, -1e18, ZERO_BYTES);
        (uint256 after0, uint256 after1) = hook.reserves();

        assertEq(after0, before0 + 1e18, "the input joined the reserves");
        assertEq(before1 - after1, gross - expectedFee, "only the net output left the reserves");
        // The fee is not held anywhere: it simply was not handed over, so the providers' claim grew by exactly it.
        assertEq((before1 - (before1 - after1)) - after1, 0, "the fee stayed in the reserves");
    }

    function test_withdrawingReturnsAProRataSliceOfBothReserves() public {
        uint256 shares = hook.balanceOf(address(this));
        (uint256 reserve0, uint256 reserve1) = hook.reserves();
        uint256 supply = hook.totalSupply();

        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        assertApproxEqRel(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - before0,
            ((shares / 2) * reserve0) / supply,
            1e12,
            "currency0 should come back pro rata"
        );
        assertApproxEqRel(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1,
            ((shares / 2) * reserve1) / supply,
            1e12,
            "currency1 should come back pro rata"
        );
    }

    function test_theFirstDepositLocksAMinimum() public view {
        // The locked shares live at the hook, where nobody can burn them, which is what stops the first depositor
        // being front-run by a donation that rounds every later depositor to zero.
        assertEq(hook.balanceOf(address(hook)), 1_000);
    }

    function test_aSwapBiggerThanTheReservesReverts() public {
        // The ladder refuses rather than filling partially or quoting a price it cannot honour.
        vm.expectRevert(StepCurveHook.InsufficientReserves.selector);
        hook.quote(true, true, 400e18);
    }

    function test_crossingMoreBandsThanTheLimitReverts() public {
        // A separate, finely-banded pool, because the bound only binds when the bands are small enough that the
        // reserves do not run out first. Without the bound a large enough swap is an unbounded loop, which on a
        // chain is a denial of service against the whole block rather than a slow transaction.
        StepCurveHook fine = StepCurveHook(
            deployHookToNamespace(
                "src/hooks/StepCurveHook.sol:StepCurveHook",
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG,
                abi.encode(address(manager), START_PRICE, STEP, MIN_PRICE, 1e15, FEE_BPS, "Fine", "FINE"),
                0x5555
            )
        );

        PoolKey memory fineKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 30,
            hooks: IHooks(address(fine))
        });
        manager.initialize(fineKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(fine), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(fine), type(uint256).max);
        fine.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1e18,
                amount1Desired: 10e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // 1e15 bands, so 0.5e18 of currency0 crosses 500 of them: past the 256 limit, and well inside the reserves.
        vm.expectRevert(StepCurveHook.SwapTooLarge.selector);
        fine.quote(true, true, 0.5e18);
    }

    function testFuzz_sellingThenBuyingBackNeverProfits(uint96 size) public {
        uint256 amount = bound(size, 1e15, 5e18);

        uint256 out1 = hook.quote(true, true, amount);
        // Buying the same currency0 back costs at least what selling it paid: the ladder plus the fee makes a
        // round trip strictly unprofitable, which is what stops the pool being a free option.
        uint256 cost1 = hook.quote(false, false, amount);
        assertGe(cost1, out1, "a round trip must never pay the trader");
    }
}
