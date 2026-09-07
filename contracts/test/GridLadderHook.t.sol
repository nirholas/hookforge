// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";

import {GridLadderHook} from "src/hooks/GridLadderHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract GridLadderHookTest is ForgeTest {
    GridLadderHook internal hook;
    PoolKey internal poolKey;

    uint256 internal constant Q96 = 1 << 96;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        setUpForge();
        hook = GridLadderHook(deployHookTo("src/hooks/GridLadderHook.sol:GridLadderHook", FLAGS, _args(9_900, 10_100)));

        poolKey = PoolKey(currency0, currency1, 0, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 50e18,
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

    /// @dev Bid and ask a hundred basis points either side of a 1.0 mid, both stepping down with inventory.
    function _args(uint256 bidBps, uint256 askBps) private view returns (bytes memory) {
        GridLadderHook.Ladder memory bid = GridLadderHook.Ladder({
            baseX96: (Q96 * bidBps) / 10_000,
            stepX96: Q96 / 1_000,
            floorX96: Q96 / 2,
            bandSize: 1e18
        });
        GridLadderHook.Ladder memory ask = GridLadderHook.Ladder({
            baseX96: (Q96 * askBps) / 10_000,
            stepX96: Q96 / 1_000,
            floorX96: (Q96 * 55) / 100,
            bandSize: 1e18
        });
        return abi.encode(address(manager), bid, ask, "Grid LP", "GRID-LP");
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "GridLadder");
    }

    function test_thePoolQuotesTwoSides() public view {
        uint256 bidPrice = hook.currentBidX96();
        uint256 askPrice = hook.currentAskX96();
        assertGt(askPrice, bidPrice, "the ask must sit above the bid");
        assertEq(hook.currentSpreadX96(), askPrice - bidPrice, "the spread is the gap between them");
    }

    function test_aCrossedBookIsRefused() public {
        // An ask below the bid would pay people to round-trip the pool.
        vm.expectRevert(GridLadderHook.CrossedBook.selector);
        deployHookToNamespace(
            "src/hooks/GridLadderHook.sol:GridLadderHook", FLAGS, _args(10_100, 9_900), 0xD111
        );
    }

    function test_aZeroBandIsRefused() public {
        GridLadderHook.Ladder memory broken =
            GridLadderHook.Ladder({baseX96: Q96, stepX96: Q96 / 1_000, floorX96: Q96 / 2, bandSize: 0});
        vm.expectRevert(GridLadderHook.InvalidLadder.selector);
        deployHookToNamespace(
            "src/hooks/GridLadderHook.sol:GridLadderHook",
            FLAGS,
            abi.encode(address(manager), broken, broken, "x", "X"),
            0xD222
        );
    }

    function test_sellingFillsAgainstTheBid_buyingAgainstTheAsk() public view {
        // One unit of currency0 sold should fetch about the bid; one unit bought should cost about the ask.
        uint256 proceeds = hook.quote(true, true, 1e18);
        uint256 cost = hook.quote(false, false, 1e18);
        assertGt(cost, proceeds, "buying a unit must cost more than selling one fetches: that is the spread");

        assertApproxEqRel(proceeds, (1e18 * hook.currentBidX96()) / Q96, 1e15, "a sale fills near the bid");
    }

    function test_theSpreadIsTheProvidersRevenue() public {
        // Sell a unit and buy it straight back: the trader ends down, and the reserves end up holding the difference.
        uint256 start1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 start0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        swap(poolKey, true, -1e18, ZERO_BYTES); // sell 1 currency0
        swap(poolKey, false, 1e18, ZERO_BYTES); // buy 1 currency0 back

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), start0, "back to the same currency0");
        assertLt(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), start1, "and down by the spread");
    }

    function test_bothLaddersStepDownAsInventoryRises() public {
        uint256 bidBefore = hook.currentBidX96();
        uint256 askBefore = hook.currentAskX96();

        swap(poolKey, true, -3e18, ZERO_BYTES); // push three bands of currency0 into the pool

        assertLt(hook.currentBidX96(), bidBefore, "the pool bids lower once it holds more");
        assertLt(hook.currentAskX96(), askBefore, "and offers lower too");
        assertGt(hook.currentAskX96(), hook.currentBidX96(), "but the book never crosses");
    }

    function test_theBookNeverCrossesAnywhereOnTheLadder() public view {
        // Walk the whole inventory range and compare the two ladders at each band. This is the invariant the
        // constructor's check is meant to guarantee, tested against the price function the swap actually uses
        // rather than against the constructor's own reasoning.
        for (uint256 r0 = 0; r0 <= 80e18; r0 += 0.5e18) {
            assertGe(hook.askAtX96(r0), hook.bidAtX96(r0), "the ask must never fall below the bid");
        }
    }

    function test_bothLaddersAreMonotoneAndBottomOut() public view {
        uint256 previousBid = type(uint256).max;
        uint256 previousAsk = type(uint256).max;
        for (uint256 r0 = 0; r0 <= 200e18; r0 += 5e18) {
            uint256 currentBid = hook.bidAtX96(r0);
            uint256 currentAsk = hook.askAtX96(r0);
            assertLe(currentBid, previousBid, "the bid must never rise as inventory grows");
            assertLe(currentAsk, previousAsk, "nor the ask");
            previousBid = currentBid;
            previousAsk = currentAsk;
        }
        // Deep enough into the ladder, both sit on their floors and stop moving.
        assertEq(hook.bidAtX96(10_000e18), Q96 / 2, "the bid bottoms out on its floor");
        assertEq(hook.askAtX96(10_000e18), (Q96 * 55) / 100, "and the ask on its own");
    }

    function test_swapPaysExactlyTheQuote() public {
        uint256 quoted = hook.quote(true, true, 1e18);
        BalanceDelta delta = swap(poolKey, true, -1e18, ZERO_BYTES);
        assertEq(delta.amount0(), -1e18);
        assertEq(uint256(uint128(delta.amount1())), quoted, "output is exactly what was quoted");
    }

    function test_aSwapBiggerThanTheReservesReverts() public {
        vm.expectRevert(GridLadderHook.InsufficientReserves.selector);
        hook.quote(true, true, 500e18);
    }

    function testFuzz_buyingAlwaysCostsMoreThanSellingFetches(uint96 size) public view {
        uint256 amount = bound(size, 1e15, 5e18);
        uint256 proceeds = hook.quote(true, true, amount);
        uint256 cost = hook.quote(false, false, amount);
        assertGt(cost, proceeds, "the spread must hold at every size");
    }
}
