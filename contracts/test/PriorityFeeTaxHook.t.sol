// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {PriorityFeeTaxHook} from "src/hooks/PriorityFeeTaxHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract PriorityFeeTaxHookTest is ForgeTest {
    PriorityFeeTaxHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant BASE_FEE = 500; // 0.05% for flow that does not bid for position
    uint24 internal constant MAX_SURCHARGE = 9_500; // up to 0.95% more
    uint128 internal constant HALF_PRIORITY = 1 gwei; // 1 gwei of priority is half the cap

    uint256 internal constant BASE_GAS_PRICE = 1 gwei;

    function setUp() public {
        setUpForge();

        hook = PriorityFeeTaxHook(
            deployHookTo(
                "src/hooks/PriorityFeeTaxHook.sol:PriorityFeeTaxHook",
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
            PriorityFeeTaxHook.Config({
                baseFee: BASE_FEE,
                maxSurcharge: MAX_SURCHARGE,
                halfPriorityWei: HALF_PRIORITY
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        // A base fee of 1 gwei, so priority fee is whatever the test sets above it.
        vm.fee(BASE_GAS_PRICE);
    }

    /// @dev Put the transaction's priority fee at exactly `priorityWei` per gas.
    function _bid(uint256 priorityWei) private {
        vm.txGasPrice(BASE_GAS_PRICE + priorityWei);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "PriorityFeeTax");
        assertEq(hook.specURI(), "https://hookforge.dev/schema/hooks/priority-fee-tax.json");
    }

    function test_configure_afterInitialize_reverts() public {
        vm.expectRevert(PoolConfigurable.PoolAlreadyInitialized.selector);
        hook.configure(
            poolKey, PriorityFeeTaxHook.Config({baseFee: 1, maxSurcharge: 1, halfPriorityWei: 1})
        );
    }

    function test_configure_zeroHalfPriority_reverts() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(PriorityFeeTaxHook.InvalidHalfPriority.selector);
        hook.configure(other, PriorityFeeTaxHook.Config({baseFee: 500, maxSurcharge: 500, halfPriorityWei: 0}));
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

    function test_noPriorityFee_chargesBaseFee() public {
        _bid(0);
        assertEq(hook.currentPriorityFee(), 0);
        assertEq(hook.quoteFee(poolId), BASE_FEE);
    }

    function test_gasPriceBelowBaseFee_treatedAsZero() public {
        // An `eth_call` with no gas price set must not underflow or over-charge.
        vm.txGasPrice(0);
        assertEq(hook.currentPriorityFee(), 0);
        assertEq(hook.quoteFee(poolId), BASE_FEE);
    }

    function test_halfPriorityBid_chargesHalfTheCap() public {
        _bid(HALF_PRIORITY);
        assertEq(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE / 2);
    }

    function test_hugeBid_saturatesBelowCap() public {
        _bid(1_000 gwei);
        uint24 fee = hook.quoteFee(poolId);
        assertGt(fee, BASE_FEE + (MAX_SURCHARGE * 99) / 100);
        assertLt(fee, BASE_FEE + MAX_SURCHARGE);
    }

    function test_swap_emitsObservedPriorityFee() public {
        _bid(HALF_PRIORITY);

        vm.recordLogs();
        swap(poolKey, true, -1e15, ZERO_BYTES);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == PriorityFeeTaxHook.PriorityPriced.selector) {
                (uint256 priority, uint24 fee) = abi.decode(logs[i].data, (uint256, uint24));
                assertEq(priority, HALF_PRIORITY);
                assertEq(fee, BASE_FEE + MAX_SURCHARGE / 2);
                found = true;
            }
        }
        assertTrue(found, "PriorityPriced not emitted");
    }

    function test_swap_racingFlowReceivesLessThanPatientFlow() public {
        _bid(0);
        BalanceDelta patient = swap(poolKey, true, -1e15, ZERO_BYTES);

        _bid(20 gwei);
        BalanceDelta racing = swap(poolKey, true, -1e15, ZERO_BYTES);

        assertEq(patient.amount0(), racing.amount0(), "inputs differ");
        assertLt(racing.amount1(), patient.amount1(), "the bidder should pay more for the same swap");
    }

    function testFuzz_feeIsBoundedAndMonotone(uint128 bidA, uint128 bidB) public {
        bidA = uint128(bound(bidA, 0, 10_000 gwei));
        bidB = uint128(bound(bidB, bidA, 10_000 gwei));

        _bid(bidA);
        uint24 feeA = hook.quoteFee(poolId);
        _bid(bidB);
        uint24 feeB = hook.quoteFee(poolId);

        assertGe(feeA, BASE_FEE);
        assertLe(feeB, BASE_FEE + MAX_SURCHARGE);
        assertGe(feeB, feeA);
    }
}
