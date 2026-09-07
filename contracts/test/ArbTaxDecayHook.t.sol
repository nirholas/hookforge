// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ArbTaxDecayHook} from "src/hooks/ArbTaxDecayHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract ArbTaxDecayHookTest is ForgeTest {
    ArbTaxDecayHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant BASE_FEE = 500; // 0.05%
    uint24 internal constant MAX_SURCHARGE = 9_500; // up to 0.95% more
    uint32 internal constant HALF_LIFE = 600; // 10 minutes of quiet is half the cap

    function setUp() public {
        setUpForge();

        hook = ArbTaxDecayHook(
            deployHookTo(
                "src/hooks/ArbTaxDecayHook.sol:ArbTaxDecayHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
                abi.encode(address(manager))
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

        hook.configure(
            poolKey,
            ArbTaxDecayHook.Config({baseFee: BASE_FEE, maxSurcharge: MAX_SURCHARGE, halfLife: HALF_LIFE})
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ArbTaxDecay");
        assertEq(hook.specURI(), "https://hookforge.pages.dev/schema/hooks/arb-tax-decay.json");
    }

    function test_configure_storesParameters() public view {
        (uint24 baseFee, uint24 maxSurcharge, uint32 halfLife) = hook.configOf(poolId);
        assertEq(baseFee, BASE_FEE);
        assertEq(maxSurcharge, MAX_SURCHARGE);
        assertEq(halfLife, HALF_LIFE);
    }

    function test_configure_afterInitialize_reverts() public {
        vm.expectRevert(PoolConfigurable.PoolAlreadyInitialized.selector);
        hook.configure(poolKey, ArbTaxDecayHook.Config({baseFee: 1, maxSurcharge: 1, halfLife: 1}));
    }

    function test_configure_zeroHalfLife_reverts() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(ArbTaxDecayHook.InvalidHalfLife.selector);
        hook.configure(other, ArbTaxDecayHook.Config({baseFee: 500, maxSurcharge: 500, halfLife: 0}));
    }

    function test_configure_surchargeOverMax_reverts() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(ArbTaxDecayHook.SurchargeTooLarge.selector);
        hook.configure(other, ArbTaxDecayHook.Config({baseFee: 999_999, maxSurcharge: 2, halfLife: 60}));
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

    function test_freshPool_chargesBaseFee() public view {
        // The staleness clock starts at initialization, so a swap in the same second pays only the base fee.
        assertEq(hook.quoteFee(poolId), BASE_FEE);
    }

    function test_surcharge_reachesHalfCapAtHalfLife() public {
        vm.warp(block.timestamp + HALF_LIFE);
        assertEq(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE / 2);
    }

    function test_surcharge_growsMonotonicallyAndSaturates() public {
        uint24 previous = hook.quoteFee(poolId);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= 20; i++) {
            vm.warp(start + i * 300);
            uint24 current = hook.quoteFee(poolId);
            assertGe(current, previous, "fee must not decrease as the pool goes stale");
            assertLe(current, BASE_FEE + MAX_SURCHARGE, "fee must never exceed base + cap");
            previous = current;
        }
        // A day of silence is deep into saturation but still strictly under the cap.
        vm.warp(start + 86_400);
        assertGt(hook.quoteFee(poolId), BASE_FEE + (MAX_SURCHARGE * 99) / 100);
        assertLt(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE);
    }

    function test_swap_appliesStalenessFeeAndResetsClock() public {
        vm.warp(block.timestamp + HALF_LIFE);

        vm.recordLogs();
        swap(poolKey, true, -1e15, ZERO_BYTES);

        (bytes memory data, bool found) = _findStalenessLog();
        assertTrue(found, "StalenessPriced not emitted");
        (uint256 elapsed, uint24 fee) = abi.decode(data, (uint256, uint24));
        assertEq(elapsed, HALF_LIFE);
        assertEq(fee, BASE_FEE + MAX_SURCHARGE / 2);

        // The swap restarted the clock, so an immediate follow-up pays only the base fee.
        assertEq(hook.lastTradeAt(poolId), uint64(block.timestamp));
        assertEq(hook.quoteFee(poolId), BASE_FEE);
    }

    function test_swap_staleSwapCostsMoreThanFreshSwap() public {
        // Fresh swap: base fee only.
        BalanceDelta fresh = swap(poolKey, true, -1e15, ZERO_BYTES);

        // Let the pool go stale, then swap the identical size.
        vm.warp(block.timestamp + 4 * HALF_LIFE);
        BalanceDelta stale = swap(poolKey, true, -1e15, ZERO_BYTES);

        // Both spend the same input; the stale swap must receive strictly less output.
        assertEq(fresh.amount0(), stale.amount0(), "inputs differ");
        assertLt(stale.amount1(), fresh.amount1(), "stale swap should receive less for the same input");
    }

    function testFuzz_feeIsBoundedAndMonotone(uint32 elapsedA, uint32 elapsedB) public {
        elapsedA = uint32(bound(elapsedA, 0, 365 days));
        elapsedB = uint32(bound(elapsedB, elapsedA, 365 days));
        uint256 start = block.timestamp;

        vm.warp(start + elapsedA);
        uint24 feeA = hook.quoteFee(poolId);
        vm.warp(start + elapsedB);
        uint24 feeB = hook.quoteFee(poolId);

        assertGe(feeA, BASE_FEE);
        assertLe(feeB, BASE_FEE + MAX_SURCHARGE);
        assertGe(feeB, feeA);
    }

    function _findStalenessLog() private view returns (bytes memory data, bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = ArbTaxDecayHook.StalenessPriced.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) return (logs[i].data, true);
        }
    }

    function test_theParameterisedPreviewAgreesWithTheLiveQuote() public {
        // The preview exists so a client can plot the curve without simulating a chain forward. It is only useful
        // if it is the same function the pool actually charges, so assert that at several points.
        uint256 start = block.timestamp;
        for (uint256 elapsed = 0; elapsed <= 4 * HALF_LIFE; elapsed += HALF_LIFE / 3) {
            vm.warp(start + elapsed);
            assertEq(hook.feeAfter(poolId, elapsed), hook.quoteFee(poolId), "preview must match the live quote");
        }
    }
}
