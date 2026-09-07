// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";

import {YieldSpaceHook} from "src/hooks/YieldSpaceHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract YieldSpaceHookTest is ForgeTest {
    YieldSpaceHook internal hook;
    PoolKey internal poolKey;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant FEE_BPS = 10;
    uint256 internal maturity;

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);
        maturity = block.timestamp + 180 days;

        hook = YieldSpaceHook(
            deployHookTo(
                "src/hooks/YieldSpaceHook.sol:YieldSpaceHook",
                FLAGS,
                abi.encode(address(manager), maturity, FEE_BPS, "Yield LP", "YS-LP")
            )
        );

        poolKey = PoolKey(currency0, currency1, 0, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        _add(100e18, 100e18);
    }

    function _add(uint256 a0, uint256 a1) private {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: a0,
                amount1Desired: a1,
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
        assertMetadata(address(hook), "YieldSpace");
    }

    function test_theMaturityMustBeInTheFuture() public {
        vm.expectRevert(YieldSpaceHook.MaturityInThePast.selector);
        deployHookToNamespace(
            "src/hooks/YieldSpaceHook.sol:YieldSpaceHook",
            FLAGS,
            abi.encode(address(manager), block.timestamp, FEE_BPS, "x", "X"),
            0x9999
        );
    }

    function test_theExponentRisesTowardsOneAsMaturityApproaches() public {
        uint256 far = hook.exponent().unwrap();

        vm.warp(maturity - 30 days);
        uint256 near = hook.exponent().unwrap();
        assertGt(near, far, "the exponent should rise as maturity approaches");

        vm.warp(maturity);
        assertEq(hook.exponent().unwrap(), 1e18, "at maturity the curve is constant-sum");
    }

    function test_atMaturityThePoolTradesOneForOne() public {
        vm.warp(maturity);
        // x + y = k, so a swap gives back exactly what it put in, less the fee.
        uint256 out = hook.quoteGross(true, true, 1e18);
        assertApproxEqRel(out, 1e18, 1e12, "a matured pool trades at par");
    }

    function test_beforeMaturityTheClaimTradesAtADiscount() public {
        // Push the pool so it holds more of the claim than the underlying, which is what a discount looks like.
        swap(poolKey, false, -20e18, ZERO_BYTES);

        uint256 rate = hook.impliedRate();
        assertGt(rate, 0, "a pool holding the claim at a discount should quote a positive rate");
        assertLt(rate, 5e18, "and not an absurd one");
    }

    function test_theRateFallsToZeroAtMaturity() public {
        swap(poolKey, false, -20e18, ZERO_BYTES);
        assertGt(hook.impliedRate(), 0);

        vm.warp(maturity);
        assertEq(hook.impliedRate(), 0, "there is no rate left once there is no time left");
    }

    function test_theInvariantIsNeverReducedByASwap() public {
        uint256 before = hook.invariant();
        swap(poolKey, true, -5e18, ZERO_BYTES);
        assertGe(hook.invariant(), before, "a swap must never reduce the invariant");
    }

    function test_swapPaysExactlyTheQuote() public {
        uint256 quoted = hook.quote(true, true, 1e18);
        BalanceDelta delta = swap(poolKey, true, -1e18, ZERO_BYTES);
        assertEq(delta.amount0(), -1e18, "input is what was specified");
        assertEq(uint256(uint128(delta.amount1())), quoted, "output is exactly what was quoted");
    }

    function test_convergenceIsTheCurveRatherThanAnArbitrage() public {
        // The property the hook exists for. Hold the reserves still and let time pass: the price the pool quotes for
        // the claim rises towards par on its own, with nobody trading against it.
        swap(poolKey, false, -20e18, ZERO_BYTES);
        uint256 early = hook.quoteGross(true, true, 1e18);

        vm.warp(maturity - 1 days);
        uint256 late = hook.quoteGross(true, true, 1e18);

        assertLt(late, early, "as maturity nears, a unit of the underlying buys less of the claim: it has converged");
    }

    function test_buyingMoreThanTheReservesReverts() public {
        vm.expectRevert(YieldSpaceHook.InsufficientReserves.selector);
        hook.quote(true, false, 200e18);
    }

    function test_aRealRoundTripLosesMoney() public {
        uint256 start0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        BalanceDelta out = swap(poolKey, true, -1e18, ZERO_BYTES);
        swap(poolKey, false, -int256(uint256(uint128(out.amount1()))), ZERO_BYTES);
        assertLt(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), start0, "a round trip costs the fee");
    }

    function testFuzz_quotesAreMonotoneInSize(uint96 a, uint96 b) public view {
        uint256 small = bound(a, 1e15, 5e18);
        uint256 large = bound(b, small, 30e18);
        assertGe(hook.quote(true, true, large), hook.quote(true, true, small), "more in, no less out");
    }

    function testFuzz_theInvariantHoldsAcrossAnySwap(uint96 size, bool zeroForOne) public {
        uint256 amount = bound(size, 1e15, 20e18);
        uint256 before = hook.invariant();
        swap(poolKey, zeroForOne, -int256(amount), ZERO_BYTES);
        assertGe(hook.invariant(), before, "the invariant only ever grows, by the fee");
    }
}
