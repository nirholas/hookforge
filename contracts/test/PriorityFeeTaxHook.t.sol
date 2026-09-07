// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {PriorityFeeTaxHook} from "src/hooks/PriorityFeeTaxHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";

contract PriorityFeeTaxHookTest is ForgeTest {
    PriorityFeeTaxHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant BASE_FEE = 500; // 0.05%
    uint24 internal constant MAX_SURCHARGE = 9500; // up to 1.00% in total
    uint128 internal constant HALF_PRIORITY = 1 gwei;

    uint256 internal constant BASE_FEE_WEI = 1 gwei;

    function setUp() public {
        setUpForge();

        hook = PriorityFeeTaxHook(
            deployHookTo(
                "src/hooks/PriorityFeeTaxHook.sol:PriorityFeeTaxHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, PriorityFeeTaxHook.Config(BASE_FEE, MAX_SURCHARGE, HALF_PRIORITY));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.fee(BASE_FEE_WEI);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "PriorityFeeTax");
    }

    function test_initialize_withoutConfiguration_reverts() public {
        PoolKey memory unconfigured =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PoolConfigurable.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(unconfigured, SQRT_PRICE_1_1);
    }

    function test_configure_zeroHalfPriority_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        vm.expectRevert(PriorityFeeTaxHook.InvalidHalfPriority.selector);
        hook.configure(other, PriorityFeeTaxHook.Config(BASE_FEE, MAX_SURCHARGE, 0));
    }

    function test_noPriorityFee_paysBaseFee() public {
        vm.txGasPrice(BASE_FEE_WEI);
        assertEq(hook.currentPriorityFee(), 0);
        assertEq(hook.quoteFee(poolId), BASE_FEE);

        vm.expectEmit(true, false, false, true, address(hook));
        emit PriorityFeeTaxHook.PriorityPriced(poolId, 0, BASE_FEE);
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_halfPriority_paysHalfTheSurcharge() public {
        vm.txGasPrice(BASE_FEE_WEI + HALF_PRIORITY);
        assertEq(hook.currentPriorityFee(), HALF_PRIORITY);
        assertEq(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE / 2);

        vm.expectEmit(true, false, false, true, address(hook));
        emit PriorityFeeTaxHook.PriorityPriced(poolId, HALF_PRIORITY, BASE_FEE + MAX_SURCHARGE / 2);
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_racingCostsMoreThanWaiting() public {
        uint256 patient = _amountOutAtPriority(0);
        uint256 racing = _amountOutAtPriority(5 gwei);
        assertLt(racing, patient, "bidding for position must cost the trader more");
    }

    function test_surchargeIsCapped() public {
        vm.txGasPrice(BASE_FEE_WEI + 10_000 gwei);
        uint24 fee = hook.quoteFee(poolId);
        assertLt(fee, BASE_FEE + MAX_SURCHARGE);
        assertGt(fee, BASE_FEE + MAX_SURCHARGE - 20);
    }

    function testFuzz_feeIsMonotoneAndBounded(uint56 priority) public {
        vm.txGasPrice(BASE_FEE_WEI + priority);
        uint24 fee = hook.quoteFee(poolId);
        assertGe(fee, BASE_FEE);
        assertLe(fee, BASE_FEE + MAX_SURCHARGE);
    }

    function testFuzz_higherBidNeverPaysLess(uint56 a, uint56 b) public {
        vm.assume(a < b);

        vm.txGasPrice(BASE_FEE_WEI + a);
        uint24 feeA = hook.quoteFee(poolId);
        vm.txGasPrice(BASE_FEE_WEI + b);
        uint24 feeB = hook.quoteFee(poolId);

        assertGe(feeB, feeA);
    }

    function _amountOutAtPriority(uint256 priority) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        vm.txGasPrice(BASE_FEE_WEI + priority);
        out = uint256(uint128(swap(poolKey, true, -1e15, ZERO_BYTES).amount1()));
        vm.revertToState(snapshot);
    }
}
