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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ExpirySettleHook} from "src/hooks/ExpirySettleHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract ExpirySettleHookTest is ForgeTest {
    using StateLibrary for IPoolManager;

    ExpirySettleHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint64 internal maturity;
    uint32 internal constant WINDOW = 1 hours;
    uint24 internal constant BASE_FEE = 500; // 0.05% for ordinary trading
    uint24 internal constant SETTLEMENT_FEE = 50_000; // 5% in the final instant

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);
        maturity = uint64(block.timestamp + 30 days);

        hook = ExpirySettleHook(
            deployHookTo(
                "src/hooks/ExpirySettleHook.sol:ExpirySettleHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG,
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

    function _config() private view returns (ExpirySettleHook.Config memory) {
        return ExpirySettleHook.Config({
            maturity: maturity,
            windowSeconds: WINDOW,
            baseFee: BASE_FEE,
            settlementFee: SETTLEMENT_FEE
        });
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ExpirySettle");
    }

    function test_configure_rejectsBadParameters() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;

        ExpirySettleHook.Config memory cfg = _config();
        cfg.windowSeconds = 0;
        vm.expectRevert(ExpirySettleHook.InvalidWindow.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.maturity = uint64(block.timestamp + WINDOW); // starts already inside its own window
        vm.expectRevert(ExpirySettleHook.MaturityTooSoon.selector);
        hook.configure(other, cfg);

        cfg = _config();
        cfg.settlementFee = BASE_FEE - 1;
        vm.expectRevert(ExpirySettleHook.SettlementFeeBelowBase.selector);
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

    function test_outsideTheWindow_chargesTheBaseFee() public view {
        assertEq(hook.feeAt(poolId, block.timestamp), BASE_FEE);
        assertEq(hook.feeAt(poolId, maturity - WINDOW), BASE_FEE, "the window opens exactly at maturity minus window");
    }

    function test_theRampIsQuadratic_soTheLastMomentsCostMost() public view {
        // At the halfway point of the window a linear ramp would be at half the spread; a quadratic one is at a
        // quarter. That difference is the whole design: cheap early, dear late.
        uint24 half = hook.feeAt(poolId, maturity - WINDOW / 2);
        uint256 spread = SETTLEMENT_FEE - BASE_FEE;
        assertEq(half, BASE_FEE + uint24(spread / 4), "halfway through the window should cost a quarter of the spread");

        uint24 threeQuarters = hook.feeAt(poolId, maturity - WINDOW / 4);
        assertEq(threeQuarters, BASE_FEE + uint24((spread * 9) / 16));

        // The last second before maturity is close to the full settlement fee.
        assertGt(hook.feeAt(poolId, maturity - 1), BASE_FEE + (spread * 99) / 100);
    }

    function test_theRampIsMonotonic() public view {
        uint24 previous = hook.feeAt(poolId, maturity - WINDOW - 1);
        for (uint256 t = WINDOW; t > 0; t -= 60) {
            uint24 current = hook.feeAt(poolId, maturity - t);
            assertGe(current, previous, "the fee must never fall as maturity approaches");
            assertLe(current, SETTLEMENT_FEE, "the fee must never exceed the settlement fee");
            previous = current;
        }
    }

    function test_swappingLaterInTheWindowCostsMore() public {
        vm.warp(maturity - WINDOW + 1);
        BalanceDelta early = swap(poolKey, true, -1e15, ZERO_BYTES);

        vm.warp(maturity - 60);
        BalanceDelta late = swap(poolKey, true, -1e15, ZERO_BYTES);

        assertEq(early.amount0(), late.amount0(), "inputs differ");
        assertLt(late.amount1(), early.amount1(), "moving the price near settlement must cost more");
    }

    function test_afterMaturity_swapsRevert() public {
        vm.warp(maturity);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ExpirySettleHook.Matured.selector, maturity),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_afterMaturity_addingLiquidityReverts() public {
        vm.warp(maturity);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ExpirySettleHook.Matured.selector, maturity),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(-12000, 12000, 1e18, bytes32(0)), ZERO_BYTES);
    }

    function test_afterMaturity_liquidityCanAlwaysLeave() public {
        vm.warp(maturity + 7 days);
        // The property that stops a matured pool being a trap: exit is never blocked, at any point in this contract.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, -1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function test_settlementPrice_isTheFinalTick_andIsStable() public {
        vm.warp(maturity - 2 hours);
        swap(poolKey, true, -5e17, ZERO_BYTES);
        (uint160 beforeSqrt, int24 beforeTick) = _slot0();

        vm.warp(maturity);
        (uint160 settledSqrt, int24 settledTick) = hook.settlementPrice(poolId);
        assertEq(settledSqrt, beforeSqrt, "the last traded price is the settlement price");
        assertEq(settledTick, beforeTick);

        // Nothing can move it afterwards, because nothing can trade.
        vm.warp(maturity + 30 days);
        (uint160 laterSqrt,) = hook.settlementPrice(poolId);
        assertEq(laterSqrt, settledSqrt, "a settled price must never move again");
    }

    function test_settlementPrice_beforeMaturity_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ExpirySettleHook.NotYetMatured.selector, maturity));
        hook.settlementPrice(poolId);
    }

    function testFuzz_feeIsBoundedAndMonotoneInTime(uint32 secondsBefore) public view {
        uint256 t = bound(secondsBefore, 0, 60 days);
        uint256 earlier = t >= maturity ? 0 : maturity - t;

        uint24 fee = hook.feeAt(poolId, earlier);
        assertGe(fee, BASE_FEE);
        assertLe(fee, SETTLEMENT_FEE);

        if (earlier > 0) {
            assertGe(hook.feeAt(poolId, earlier + 1), fee, "later is never cheaper");
        }
    }

    function _slot0() private view returns (uint160 sqrtPriceX96, int24 tick) {
        return (poolSqrtPrice(poolKey), _tick());
    }

    function _tick() private view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }
}
