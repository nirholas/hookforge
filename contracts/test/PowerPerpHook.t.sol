// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";

import {PowerPerpHook} from "src/hooks/PowerPerpHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract PowerPerpHookTest is ForgeTest {
    PowerPerpHook internal balanced; // 50/50, the ordinary constant-product pool
    PowerPerpHook internal heavy; // 80/20, a provider who wants most of currency0's move

    PoolKey internal balancedKey;
    PoolKey internal heavyKey;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant FEE_BPS = 30;

    function setUp() public {
        setUpForge();

        balanced = PowerPerpHook(
            deployHookToNamespace(
                "src/hooks/PowerPerpHook.sol:PowerPerpHook",
                FLAGS,
                abi.encode(address(manager), 5_000, FEE_BPS, "Balanced LP", "BAL-LP"),
                0x4444
            )
        );
        heavy = PowerPerpHook(
            deployHookToNamespace(
                "src/hooks/PowerPerpHook.sol:PowerPerpHook",
                FLAGS,
                abi.encode(address(manager), 8_000, FEE_BPS, "Heavy LP", "HVY-LP"),
                0x5555
            )
        );

        balancedKey = PoolKey(currency0, currency1, 0, 60, IHooks(address(balanced)));
        heavyKey = PoolKey(currency0, currency1, 0, 120, IHooks(address(heavy)));
        manager.initialize(balancedKey, SQRT_PRICE_1_1);
        manager.initialize(heavyKey, SQRT_PRICE_1_1);

        for (uint256 i = 0; i < 2; i++) {
            PowerPerpHook hook = i == 0 ? balanced : heavy;
            IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            hook.addLiquidity(
                BaseCustomAccounting.AddLiquidityParams({
                    amount0Desired: 100e18,
                    amount1Desired: 100e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 1,
                    tickLower: 0,
                    tickUpper: 0,
                    userInputSalt: bytes32(0)
                })
            );
        }
    }

    function test_metadata() public view {
        assertMetadata(address(balanced), "PowerPerp");
    }

    function test_theWeightMustLeaveBothSidesAShare() public {
        // Deployed to a flag-valid address, because BaseHook checks the address before the constructor body runs
        // and a plain `new` would fail on that instead of on the weight.
        vm.expectRevert(PowerPerpHook.InvalidWeight.selector);
        deployHookToNamespace(
            "src/hooks/PowerPerpHook.sol:PowerPerpHook",
            FLAGS,
            abi.encode(address(manager), 500, FEE_BPS, "x", "X"),
            0x7777
        );

        vm.expectRevert(PowerPerpHook.InvalidWeight.selector);
        deployHookToNamespace(
            "src/hooks/PowerPerpHook.sol:PowerPerpHook",
            FLAGS,
            abi.encode(address(manager), 9_500, FEE_BPS, "x", "X"),
            0x8888
        );
    }

    function test_aBalancedPoolIsTheConstantProductPool() public view {
        // With equal weights and equal reserves the invariant is just the reserve, and the spot price is 1.
        assertApproxEqRel(balanced.invariant(), 100e18, 1e12, "x^0.5 * y^0.5 with x = y = 100 is 100");
        assertApproxEqRel(balanced.spotPrice(), 1e18, 1e12, "equal weights and reserves means a price of one");
    }

    function test_aWeightedPoolQuotesADifferentPrice() public view {
        // 80/20 with equal reserves: the pool wants far more currency0 than it holds relative to its weight, so
        // currency0 is priced above one.
        assertApproxEqRel(heavy.spotPrice(), 4e18, 1e12, "an 80/20 pool with equal reserves prices currency0 at 4");
    }

    function test_theInvariantIsPreservedAcrossASwap() public {
        // The fee makes the invariant grow, never shrink: that growth is exactly what pays the providers.
        uint256 before = heavy.invariant();
        swap(heavyKey, true, -1e18, ZERO_BYTES);
        uint256 afterSwap = heavy.invariant();
        assertGe(afterSwap, before, "a swap must never reduce the invariant");
        assertApproxEqRel(afterSwap, before, 1e15, "and must not move it much beyond the fee");
    }

    function test_theWeightSetsThePriceTheProviderQuotesAt() public view {
        // An 80/20 pool holding equal reserves is under-weight currency0 relative to what it wants, so it prices
        // currency0 above the balanced pool and pays more currency1 for the same sale. That is the weight doing its
        // job: the provider is quoting a different market, not the same market at a worse price.
        uint256 balancedOut = balanced.quote(true, true, 10e18);
        uint256 heavyOut = heavy.quote(true, true, 10e18);
        assertGt(heavyOut, balancedOut, "the pool that prices currency0 higher should pay more for it");

        // And the quotes line up with the spot prices the two pools publish.
        assertGt(heavy.spotPrice(), balanced.spotPrice());
    }

    function test_aRealRoundTripLosesMoney() public {
        // Comparing two quotes taken at the same reserves is not a round trip: no trader can execute both, because
        // the first one moves the reserves. The property that matters is the executed one, so execute it.
        uint256 start0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        BalanceDelta out = swap(balancedKey, true, -1e18, ZERO_BYTES);
        uint256 received1 = uint256(uint128(out.amount1()));
        swap(balancedKey, false, -int256(received1), ZERO_BYTES);

        uint256 end0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        assertLt(end0, start0, "selling and buying straight back must cost the trader the fee");
    }

    function test_theQuoteRoundsAgainstTheTraderOnExactOutput() public view {
        // An exact-output quote must never round down: the pool would hand over the full output having been paid
        // less than the curve requires.
        uint256 wanted = 1e18 + 1;
        uint256 gross = balanced.quoteGross(true, false, wanted);
        uint256 net = balanced.quote(true, false, wanted);
        assertGt(net, gross, "the fee is added on an exact-output swap");
        assertGe(net - gross, (gross * FEE_BPS) / 10_000, "and rounded up, never down");
    }

    function test_swapPaysExactlyTheQuote() public {
        uint256 quoted = balanced.quote(true, true, 1e18);
        BalanceDelta delta = swap(balancedKey, true, -1e18, ZERO_BYTES);
        assertEq(delta.amount0(), -1e18, "input is what was specified");
        assertEq(uint256(uint128(delta.amount1())), quoted, "output is exactly what was quoted");
    }

    function test_theFeeStaysInTheReserves() public {
        uint256 gross = balanced.quoteGross(true, true, 1e18);
        uint256 expectedFee = (gross * FEE_BPS) / 10_000;

        (uint256 before0, uint256 before1) = balanced.reserves();
        swap(balancedKey, true, -1e18, ZERO_BYTES);
        (uint256 after0, uint256 after1) = balanced.reserves();

        assertEq(after0, before0 + 1e18, "the input joined the reserves");
        assertEq(before1 - after1, gross - expectedFee, "only the net output left");
    }

    function test_buyingMoreThanTheReservesReverts() public {
        vm.expectRevert(PowerPerpHook.InsufficientReserves.selector);
        balanced.quote(true, false, 200e18);
    }

    function test_sellingIntoAnEmptyPoolReverts() public {
        PowerPerpHook empty = PowerPerpHook(
            deployHookToNamespace(
                "src/hooks/PowerPerpHook.sol:PowerPerpHook",
                FLAGS,
                abi.encode(address(manager), 5_000, FEE_BPS, "Empty", "MT"),
                0x6666
            )
        );
        PoolKey memory emptyKey = PoolKey(currency0, currency1, 0, 200, IHooks(address(empty)));
        manager.initialize(emptyKey, SQRT_PRICE_1_1);

        vm.expectRevert(PowerPerpHook.NoLiquidity.selector);
        empty.quote(true, true, 1e18);
    }

    function testFuzz_sellingAlwaysMovesThePriceAgainstTheSeller(uint96 size) public {
        uint256 amount = bound(size, 1e15, 20e18);
        uint256 priceBefore = balanced.spotPrice();
        swap(balancedKey, true, -int256(amount), ZERO_BYTES);
        assertLt(balanced.spotPrice(), priceBefore, "selling currency0 must make currency0 cheaper");
    }

    function testFuzz_quotesAreMonotoneInSize(uint96 a, uint96 b) public view {
        uint256 small = bound(a, 1e15, 5e18);
        uint256 large = bound(b, small, 20e18);
        assertGe(balanced.quote(true, true, large), balanced.quote(true, true, small), "more in, no less out");
    }
}
