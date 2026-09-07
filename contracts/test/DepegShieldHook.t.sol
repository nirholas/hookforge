// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {DepegShieldHook} from "src/hooks/DepegShieldHook.sol";

contract DepegShieldHookTest is ForgeTest {
    DepegShieldHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant PEG_TICK = 0;
    uint24 internal constant BASE_FEE = 1000; // 0.10% at par
    uint24 internal constant MIN_FEE = 100; // 0.01% floor for repairing flow
    uint24 internal constant MAX_SURCHARGE = 4000; // up to 0.50% for flow leaving the peg
    uint24 internal constant HALF_DEVIATION = 50; // half applies fifty basis points off par

    DepegShieldHook.Config internal cfg =
        DepegShieldHook.Config(PEG_TICK, BASE_FEE, MIN_FEE, MAX_SURCHARGE, HALF_DEVIATION);

    function setUp() public {
        setUpForge();

        hook = DepegShieldHook(
            deployHookTo(
                "src/hooks/DepegShieldHook.sol:DepegShieldHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, cfg);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "DepegShield");
    }

    function test_atPeg_bothDirectionsPayBaseFee() public view {
        (uint24 buy, uint256 deviation,) = hook.quoteFee(poolId, true);
        (uint24 sell,,) = hook.quoteFee(poolId, false);

        assertEq(deviation, 0);
        assertEq(buy, BASE_FEE);
        assertEq(sell, BASE_FEE);
    }

    function test_offPeg_widenerPaysMoreAndRepairerPaysLess() public {
        // Push the pool below par by selling currency0 into it.
        swap(poolKey, true, -5e17, ZERO_BYTES);

        (uint24 widening, uint256 deviation,) = hook.quoteFee(poolId, true);
        (uint24 restoring,, bool isRestoring) = hook.quoteFee(poolId, false);

        assertGt(deviation, 0, "the pool has left par");
        assertGt(widening, BASE_FEE, "flow that pushes further from par pays a surcharge");
        assertLt(restoring, BASE_FEE, "flow that repairs the pool pays a discount");
        assertTrue(isRestoring);
        assertGe(restoring, MIN_FEE);
    }

    function test_deviationChangesWhatTheTraderReceives() public {
        swap(poolKey, true, -5e17, ZERO_BYTES);

        uint256 widened = _amountOut(true);
        uint256 repaired = _amountOut(false);
        assertGt(widened, 0);
        assertGt(repaired, 0);

        (uint24 wideningFee,,) = hook.quoteFee(poolId, true);
        (uint24 restoringFee,,) = hook.quoteFee(poolId, false);
        assertGt(wideningFee, restoringFee, "the spread opens in the direction of the break");
    }

    function test_previewFee_halfDeviation_isHalfTheSurcharge() public view {
        (uint24 fee,,) = hook.previewFee(cfg, int24(int256(uint256(HALF_DEVIATION))), false);
        assertEq(fee, BASE_FEE + MAX_SURCHARGE / 2);
    }

    function test_previewFee_halfDeviation_isHalfTheDiscount() public view {
        (uint24 fee,,) = hook.previewFee(cfg, int24(int256(uint256(HALF_DEVIATION))), true);
        assertEq(fee, BASE_FEE - (BASE_FEE - MIN_FEE) / 2);
    }

    function test_previewFee_isSymmetricAroundThePeg() public view {
        // A pool fifty basis points rich in currency1 and one fifty basis points rich in currency0 are the same
        // situation mirrored, so the fee for the repairing direction must match.
        (uint24 above,,) = hook.previewFee(cfg, 50, true);
        (uint24 below,,) = hook.previewFee(cfg, -50, false);
        assertEq(above, below);
    }

    function testFuzz_previewFee_isAlwaysWithinBounds(int24 tick, bool zeroForOne) public view {
        tick = int24(bound(tick, -887272, 887272));
        (uint24 fee,,) = hook.previewFee(cfg, tick, zeroForOne);

        assertGe(fee, MIN_FEE);
        assertLe(fee, BASE_FEE + MAX_SURCHARGE);
    }

    function testFuzz_widenerNeverPaysLessThanRepairer(int24 tick) public view {
        tick = int24(bound(tick, -887272, -1));

        // Below the peg, selling currency0 pushes further away and buying it repairs.
        (uint24 widening,,) = hook.previewFee(cfg, tick, true);
        (uint24 restoring,,) = hook.previewFee(cfg, tick, false);
        assertGt(widening, restoring);
    }

    function testFuzz_surchargeGrowsWithDeviation(int24 near, int24 far) public view {
        near = int24(bound(near, 1, 400_000));
        far = int24(bound(far, int256(near), 887272));

        (uint24 feeNear,,) = hook.previewFee(cfg, near, false);
        (uint24 feeFar,,) = hook.previewFee(cfg, far, false);
        assertGe(feeFar, feeNear);
    }

    function _amountOut(bool zeroForOne) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        int128 amount = zeroForOne
            ? swap(poolKey, true, -1e15, ZERO_BYTES).amount1()
            : swap(poolKey, false, -1e15, ZERO_BYTES).amount0();
        out = uint256(uint128(amount));
        vm.revertToState(snapshot);
    }
}
