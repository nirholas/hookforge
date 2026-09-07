// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {AntiSnipeRampHook} from "src/hooks/AntiSnipeRampHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";

contract AntiSnipeRampHookTest is ForgeTest {
    AntiSnipeRampHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant START_FEE = 500_000; // 50% in the opening second
    uint24 internal constant END_FEE = 3000; // 0.30% once the ramp has run
    uint32 internal constant RAMP = 1200; // twenty minutes
    uint128 internal constant MAX_SWAP = 1e15;

    function setUp() public {
        setUpForge();

        hook = AntiSnipeRampHook(
            deployHookTo(
                "src/hooks/AntiSnipeRampHook.sol:AntiSnipeRampHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, AntiSnipeRampHook.Config(START_FEE, END_FEE, RAMP, MAX_SWAP));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "AntiSnipeRamp");
    }

    function test_openingSecond_paysTheStartFee() public {
        assertTrue(hook.isRamping(poolId));
        assertEq(hook.quoteFee(poolId), START_FEE);

        vm.expectEmit(true, false, false, true, address(hook));
        emit AntiSnipeRampHook.RampPriced(poolId, 0, START_FEE);
        swap(poolKey, true, -1e14, ZERO_BYTES);
    }

    function test_midRamp_paysTheMidpoint() public {
        vm.warp(block.timestamp + RAMP / 2);
        assertEq(hook.quoteFee(poolId), START_FEE - (START_FEE - END_FEE) / 2);
    }

    function test_afterRamp_paysTheEndFee() public {
        vm.warp(block.timestamp + RAMP);
        assertFalse(hook.isRamping(poolId));
        assertEq(hook.quoteFee(poolId), END_FEE);

        vm.warp(block.timestamp + 3650 days);
        assertEq(hook.quoteFee(poolId), END_FEE);
    }

    function test_sniperGetsLessThanAPatientBuyer() public {
        uint256 sniped = _amountOut(0);
        uint256 patient = _amountOut(RAMP);
        assertLt(sniped, patient, "buying in the opening second must be the worst price of the launch");
    }

    function test_oversizedSwapDuringRamp_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AntiSnipeRampHook.SwapTooLargeDuringRamp.selector, MAX_SWAP + 1, MAX_SWAP),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -int256(uint256(MAX_SWAP)) - 1, ZERO_BYTES);
    }

    function test_oversizedSwapAfterRamp_succeeds() public {
        vm.warp(block.timestamp + RAMP);
        swap(poolKey, true, -int256(uint256(MAX_SWAP)) * 100, ZERO_BYTES);
    }

    function test_sizeCapAppliesToExactOutputToo() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AntiSnipeRampHook.SwapTooLargeDuringRamp.selector, MAX_SWAP + 1, MAX_SWAP),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, int256(uint256(MAX_SWAP)) + 1, ZERO_BYTES);
    }

    function test_configure_rampingUpward_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        vm.expectRevert(AntiSnipeRampHook.InvalidConfig.selector);
        hook.configure(other, AntiSnipeRampHook.Config(END_FEE, START_FEE, RAMP, MAX_SWAP));
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

    function testFuzz_feeDecaysMonotonically(uint32 a, uint32 b) public {
        vm.assume(a < b);
        uint256 start = block.timestamp;

        vm.warp(start + a);
        uint24 feeA = hook.quoteFee(poolId);
        vm.warp(start + b);
        uint24 feeB = hook.quoteFee(poolId);

        assertLe(feeB, feeA);
        assertGe(feeB, END_FEE);
        assertLe(feeA, START_FEE);
    }

    function _amountOut(uint32 waitSeconds) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + waitSeconds);
        out = uint256(uint128(swap(poolKey, true, -1e14, ZERO_BYTES).amount1()));
        vm.revertToState(snapshot);
    }
}
