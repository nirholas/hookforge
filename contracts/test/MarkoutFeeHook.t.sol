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

import {MarkoutFeeHook} from "src/hooks/MarkoutFeeHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract MarkoutFeeHookTest is ForgeTest {
    MarkoutFeeHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant BASE_FEE = 500; // 0.05% when flow is measured as harmless
    uint24 internal constant MAX_SURCHARGE = 9_500; // up to 1.00% when it is measured as informed
    uint64 internal constant ALPHA = 0.5e18; // learn fast, so a test can observe convergence
    uint32 internal constant HORIZON = 60;
    uint24 internal constant SATURATION = 50; // 50 ticks of continuation reads as fully informed

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);

        hook = MarkoutFeeHook(
            deployHookTo(
                "src/hooks/MarkoutFeeHook.sol:MarkoutFeeHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG,
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

        hook.configure(poolKey, _config());
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function _config() private pure returns (MarkoutFeeHook.Config memory) {
        return MarkoutFeeHook.Config({
            baseFee: BASE_FEE,
            maxSurcharge: MAX_SURCHARGE,
            alphaWad: ALPHA,
            minHorizon: HORIZON,
            saturationTicks: SATURATION
        });
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "MarkoutFee");
        // Asserted as a suffix: the host the catalogue is served from is a deployment decision, the slug is not.
        assertTrue(_endsWith(hook.specURI(), "/schema/hooks/markout-fee.json"), "specURI should name this hook's slug");
    }

    function _endsWith(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i < n.length; i++) {
            if (h[h.length - n.length + i] != n[i]) return false;
        }
        return true;
    }

    function test_aFreshPoolChargesTheBaseFee() public view {
        assertEq(hook.toxicityOf(poolId), 0);
        assertEq(hook.quoteFee(poolId), BASE_FEE);
    }

    function test_configure_rejectsBadParameters() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;

        MarkoutFeeHook.Config memory cfg = _config();
        cfg.alphaWad = 0;
        vm.expectRevert(MarkoutFeeHook.InvalidSmoothing.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.alphaWad = 1e18 + 1;
        vm.expectRevert(MarkoutFeeHook.InvalidSmoothing.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.saturationTicks = 0;
        vm.expectRevert(MarkoutFeeHook.InvalidSaturation.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.maxSurcharge = 1_000_000;
        vm.expectRevert(MarkoutFeeHook.SurchargeTooLarge.selector);
        hook.configure(other, cfg);
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

    function test_nothingIsGradedInsideTheHorizon() public {
        swap(poolKey, true, -1e17, ZERO_BYTES);
        // A second swap in the same second is measuring the first swap's own impact, not what happened next.
        (, bool gradeable) = hook.previewGrade(poolId);
        assertFalse(gradeable, "a swap inside the horizon must not be graded");

        swap(poolKey, true, -1e17, ZERO_BYTES);
        assertEq(hook.gradedCount(poolId), 0);
        assertEq(hook.toxicityOf(poolId), 0);
        assertEq(hook.quoteFee(poolId), BASE_FEE);
    }

    function test_priceContinuing_gradesTheSwapInformed_andRaisesTheFee() public {
        // A sells hard, and after the horizon the price has kept falling: the seller was right.
        swap(poolKey, true, -1e17, ZERO_BYTES);
        vm.warp(block.timestamp + HORIZON + 1);
        swap(poolKey, true, -5e17, ZERO_BYTES);

        assertEq(hook.gradedCount(poolId), 1, "the first swap should now have been graded");
        assertGt(hook.toxicityOf(poolId), 0, "continuation is evidence of informed flow");
        assertGt(hook.quoteFee(poolId), BASE_FEE, "an informed pool should quote a higher fee");
    }

    function test_priceReverting_gradesTheSwapBenign_andKeepsTheFeeLow() public {
        // A sells, then the price comes back: the sale was noise and the fee it paid was pure revenue.
        swap(poolKey, true, -1e17, ZERO_BYTES);
        vm.warp(block.timestamp + HORIZON + 1);
        swap(poolKey, false, -3e17, ZERO_BYTES); // pushes the price back up
        vm.warp(block.timestamp + HORIZON + 1);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        assertGe(hook.gradedCount(poolId), 1);
        assertEq(hook.quoteFee(poolId), BASE_FEE, "reverting flow must not raise the fee above base");
    }

    function test_aSustainedOneWayRunReadsAsInformed() public {
        // Worth stating as a property rather than discovering as a surprise: every swap in a one-directional run is
        // graded by the next swap in that run, which pushes the price further the same way. The hook therefore treats
        // a sustained run as informed flow, which is the intended reading. Somebody who keeps selling into a falling
        // price generally does know something.
        swap(poolKey, true, -1e17, ZERO_BYTES);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + HORIZON + 1);
            swap(poolKey, true, -5e17, ZERO_BYTES);
        }

        assertGt(hook.toxicityOf(poolId), 0.5e18, "a sustained run should read as strongly informed");
        assertGt(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE / 2);
    }

    function test_theFeeDecaysBackWhenFlowStopsBeingInformed() public {
        // Drive it hot with a one-way run.
        swap(poolKey, true, -1e17, ZERO_BYTES);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + HORIZON + 1);
            swap(poolKey, true, -5e17, ZERO_BYTES);
        }
        uint24 hot = hook.quoteFee(poolId);
        assertGt(hot, BASE_FEE, "sustained continuation should have raised the fee");

        // Then alternate direction, so every swap is followed by one that takes the price back. That is what
        // uninformed two-sided flow looks like, and it is the case the fee is supposed to get cheap for.
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + HORIZON + 1);
            swap(poolKey, i % 2 == 1, -2e17, ZERO_BYTES);
        }

        assertLt(hook.quoteFee(poolId), hot, "two-sided flow must bring the fee back down");
        assertLt(hook.toxicityOf(poolId), 0.2e18, "repeated reversion should drive the score toward zero");
    }

    function test_theSurchargeIsCappedAndTheScoreStaysInRange() public {
        swap(poolKey, true, -1e17, ZERO_BYTES);
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + HORIZON + 1);
            swap(poolKey, true, -5e17, ZERO_BYTES);
        }

        assertLe(hook.toxicityOf(poolId), 1e18, "toxicity is a fraction and must never exceed one");
        assertLe(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE, "the fee must never exceed base plus the cap");
    }

    function test_aHigherFeeActuallyReachesTheSwapper() public {
        // Establish a hot pool, then compare what an identical swap receives before and after.
        BalanceDelta cheap = swap(poolKey, true, -1e15, ZERO_BYTES);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + HORIZON + 1);
            swap(poolKey, true, -5e17, ZERO_BYTES);
        }
        assertGt(hook.quoteFee(poolId), BASE_FEE);

        vm.warp(block.timestamp + HORIZON + 1);
        BalanceDelta dear = swap(poolKey, true, -1e15, ZERO_BYTES);

        assertEq(cheap.amount0(), dear.amount0(), "inputs differ");
        assertLt(dear.amount1(), cheap.amount1(), "the measured fee must actually change what the swapper receives");
    }

    function testFuzz_scoreAndFeeStayInBounds(uint8 pattern) public {
        swap(poolKey, true, -1e16, ZERO_BYTES);
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + HORIZON + 1);
            swap(poolKey, (pattern >> i) & 1 == 1, -1e16, ZERO_BYTES);

            assertLe(hook.toxicityOf(poolId), 1e18);
            assertGe(hook.quoteFee(poolId), BASE_FEE);
            assertLe(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE);
        }
    }
}
