// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {FlowClassifierHook} from "src/hooks/FlowClassifierHook.sol";
import {IFlowStats} from "src/interfaces/IFlowStats.sol";
import {Saturating} from "src/libraries/Saturating.sol";

/// @dev Exposes the saturating counters, which cannot be driven to their limits through four billion real swaps.
contract SaturatingHarness {
    function inc32(uint32 value) external pure returns (uint32) {
        return Saturating.inc32(value);
    }

    function add64(uint64 value, uint256 amount) external pure returns (uint64) {
        return Saturating.add64(value, amount);
    }
}

contract FlowClassifierHookTest is ForgeTest {
    FlowClassifierHook internal hook;
    PoolKey internal watched;
    PoolKey internal plain;
    PoolId internal watchedId;

    function setUp() public {
        vm.roll(1000);
        setUpForge();

        hook = FlowClassifierHook(
            deployHookTo(
                "src/hooks/FlowClassifierHook.sol:FlowClassifierHook",
                uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        watched = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        watchedId = watched.toId();
        manager.initialize(watched, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            watched, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );

        // An identical pool with no hook at all, so the measurement can be shown to cost the trader nothing.
        plain = PoolKey(currency0, currency1, 3000, 120, IHooks(address(0)));
        manager.initialize(plain, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            plain, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "FlowClassifier");
    }

    function test_announcesTheFlowStatsInterface() public view {
        assertTrue(hook.supportsInterface(type(IFlowStats).interfaceId), "should announce IFlowStats");
    }

    function test_anUntouchedPoolPublishesZeroes() public view {
        (uint256 swaps, uint256 lead, uint256 leadTicks, uint256 followTicks) = hook.flowStats(watchedId);
        assertEq(swaps, 0);
        assertEq(lead, 0);
        assertEq(leadTicks, 0);
        assertEq(followTicks, 0);
        assertEq(hook.leadShareBps(watchedId), 0);
        assertEq(hook.leadImpactRatioBps(watchedId), 0);
    }

    function test_theFirstSwapOfABlockLeads_theRestFollow() public {
        swap(watched, true, -1e15, ZERO_BYTES);
        swap(watched, true, -1e15, ZERO_BYTES);
        swap(watched, true, -1e15, ZERO_BYTES);

        (uint256 swaps, uint256 lead,,) = hook.flowStats(watchedId);
        assertEq(swaps, 3);
        assertEq(lead, 1, "only the first swap in the block leads it");

        vm.roll(block.number + 1);
        swap(watched, true, -1e15, ZERO_BYTES);

        (swaps, lead,,) = hook.flowStats(watchedId);
        assertEq(swaps, 4);
        assertEq(lead, 2, "a new block means a new leader");
    }

    function test_leadShareIsTheFractionOfTradesArrivingFirst() public {
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            swap(watched, true, -1e15, ZERO_BYTES); // leads
            swap(watched, false, -1e15, ZERO_BYTES); // follows
        }

        assertEq(hook.leadShareBps(watchedId), 5000, "half the trades led their block");
    }

    function test_biggerLeadingTradesRaiseTheImpactRatio() public {
        // A pool where the trade that arrives first moves the price much further than the ones that follow: the
        // signature of arbitrage rather than of ordinary flow.
        for (uint256 i = 0; i < 3; i++) {
            vm.roll(block.number + 1);
            swap(watched, true, -8e17, ZERO_BYTES);
            swap(watched, false, -1e15, ZERO_BYTES);
            swap(watched, false, -1e15, ZERO_BYTES);
        }

        uint256 ratio = hook.leadImpactRatioBps(watchedId);
        assertGt(ratio, 10_000, "the leading trades moved the price further than the ones that followed");
    }

    function test_evenFlowGivesARatioNearParity() public {
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            swap(watched, true, -1e16, ZERO_BYTES);
            swap(watched, true, -1e16, ZERO_BYTES);
        }

        uint256 ratio = hook.leadImpactRatioBps(watchedId);
        assertGt(ratio, 5_000);
        assertLt(ratio, 20_000, "two populations that behave alike must not look different");
    }

    function test_aRatioNeedsBothPopulations() public {
        // One swap per block for four blocks: everything leads, nothing follows, so there is nothing to compare.
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            swap(watched, true, -1e15, ZERO_BYTES);
        }

        assertEq(hook.leadShareBps(watchedId), 10_000, "every swap led its block");
        assertEq(hook.leadImpactRatioBps(watchedId), 0, "with no following swaps there is no ratio to report");
    }

    function test_measuringCostsTheTraderNothing() public {
        BalanceDelta measured = swap(watched, true, -1e16, ZERO_BYTES);
        BalanceDelta unmeasured = swap(plain, true, -1e16, ZERO_BYTES);

        assertEq(measured.amount0(), unmeasured.amount0(), "the hook must not change what the trader pays");
        assertEq(measured.amount1(), unmeasured.amount1(), "the hook must not change what the trader receives");
    }

    function test_countersSaturateRatherThanWrap() public {
        SaturatingHarness harness = new SaturatingHarness();

        assertEq(harness.inc32(type(uint32).max), type(uint32).max, "a full counter must not wrap to zero");
        assertEq(harness.inc32(5), 6);
        assertEq(harness.add64(type(uint64).max - 1, 1000), type(uint64).max, "a full total must not wrap");
        assertEq(harness.add64(10, 5), 15);
    }

    function testFuzz_everySwapIsCountedExactlyOnce(uint8 pattern) public {
        uint256 expected;
        for (uint256 i = 0; i < 8; i++) {
            if ((pattern >> i) & 1 == 1) vm.roll(block.number + 1);
            swap(watched, i % 2 == 0, -1e15, ZERO_BYTES);
            expected++;
        }

        (uint256 swaps, uint256 lead,,) = hook.flowStats(watchedId);
        assertEq(swaps, expected);
        assertLe(lead, swaps);
        assertGe(lead, 1, "the first swap of the test always leads its block");
    }
}
