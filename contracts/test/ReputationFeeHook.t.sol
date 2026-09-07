// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ReputationFeeHook} from "src/hooks/ReputationFeeHook.sol";
import {IAgentReputation} from "src/interfaces/IAgentReputation.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {SimpleReputationRegistry} from "./doubles/SimpleReputationRegistry.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract ReputationFeeHookTest is ForgeTest {
    ReputationFeeHook internal hook;
    SimpleReputationRegistry internal registry;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant MIN_FEE = 100; // 0.01% for a spotless counterparty
    uint24 internal constant MAX_FEE = 10_000; // 1.00% for one the pool cannot identify

    address internal goodAgent = address(0x600D);
    address internal poorAgent = address(0xBAD0);

    function setUp() public {
        setUpForge();
        registry = new SimpleReputationRegistry();

        hook = ReputationFeeHook(
            deployHookTo(
                "src/hooks/ReputationFeeHook.sol:ReputationFeeHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
                abi.encode(address(manager), address(registry))
            )
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        hook.configure(poolKey, ReputationFeeHook.Config({minFee: MIN_FEE, maxFee: MAX_FEE}));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );

        registry.set(goodAgent, 10_000);
        registry.set(poorAgent, 0);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ReputationFee");
    }

    function test_anUnknownRouterPaysTheWorstRate() public view {
        (uint24 fee, address agent,) = hook.feeFor(poolId, address(swapRouter));
        assertEq(fee, MAX_FEE, "an unidentified counterparty is priced as the worst one");
        assertEq(agent, address(0));
    }

    function test_registeringARouterAttachesTheCallersReputation() public {
        vm.prank(goodAgent);
        hook.register(address(swapRouter));

        (uint24 fee, address agent, uint256 score) = hook.feeFor(poolId, address(swapRouter));
        assertEq(agent, goodAgent);
        assertEq(score, 10_000);
        assertEq(fee, MIN_FEE, "a perfect score pays the best rate");
    }

    function test_aPoorScorePaysTheWorstRate() public {
        vm.prank(poorAgent);
        hook.register(address(swapRouter));

        (uint24 fee,,) = hook.feeFor(poolId, address(swapRouter));
        assertEq(fee, MAX_FEE, "a zero score pays what an unknown counterparty pays");
    }

    function test_theFeeInterpolatesAcrossTheRange() public {
        address middling = address(0x77);
        registry.set(middling, 5_000);
        vm.prank(middling);
        hook.register(address(swapRouter));

        (uint24 fee,,) = hook.feeFor(poolId, address(swapRouter));
        assertEq(fee, MAX_FEE - (MAX_FEE - MIN_FEE) / 2, "half a score is half the discount");
    }

    function test_deregisteringRestoresTheUnknownRate() public {
        vm.prank(goodAgent);
        hook.register(address(swapRouter));
        (uint24 discounted,,) = hook.feeFor(poolId, address(swapRouter));
        assertEq(discounted, MIN_FEE);

        vm.prank(goodAgent);
        hook.deregister(address(swapRouter));
        (uint24 restored,,) = hook.feeFor(poolId, address(swapRouter));
        assertEq(restored, MAX_FEE, "an unclaimed router is unknown again");
    }

    function test_nobodyCanDeregisterSomebodyElsesRouter() public {
        vm.prank(goodAgent);
        hook.register(address(swapRouter));

        vm.prank(poorAgent);
        hook.deregister(address(swapRouter));

        (, address agent,) = hook.feeFor(poolId, address(swapRouter));
        assertEq(agent, goodAgent, "only the agent that claimed a router may release it");
    }

    function test_theDiscountReachesTheSwapper() public {
        BalanceDelta expensive = swap(poolKey, true, -1e15, ZERO_BYTES);

        vm.prank(goodAgent);
        hook.register(address(swapRouter));
        BalanceDelta cheap = swap(poolKey, true, -1e15, ZERO_BYTES);

        assertEq(expensive.amount0(), cheap.amount0(), "inputs differ");
        assertGt(cheap.amount1(), expensive.amount1(), "a good reputation must actually buy a better fill");
    }

    function test_configure_rejectsAnInvertedSchedule() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(ReputationFeeHook.MaxBelowMin.selector);
        hook.configure(other, ReputationFeeHook.Config({minFee: 5_000, maxFee: 1_000}));
    }

    function test_initialize_withoutConfig_reverts() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PoolConfigurable.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function testFuzz_theFeeAlwaysSitsInsideTheConfiguredBand(uint256 score) public {
        uint256 bounded = bound(score, 0, 20_000); // deliberately allowed above the scale
        address agent = address(0x1234);
        registry.set(agent, bounded);
        vm.prank(agent);
        hook.register(address(swapRouter));

        (uint24 fee,,) = hook.feeFor(poolId, address(swapRouter));
        assertGe(fee, MIN_FEE);
        assertLe(fee, MAX_FEE);
    }
}
