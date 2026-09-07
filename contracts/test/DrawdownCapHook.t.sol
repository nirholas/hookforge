// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {DrawdownCapHook} from "src/hooks/DrawdownCapHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";

contract DrawdownCapHookTest is ForgeTest {
    using StateLibrary for IPoolManager;

    DrawdownCapHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant MAX_FALL = 400; // a four percent limit down
    uint32 internal constant EPOCH = 3600;

    function setUp() public {
        vm.warp(1_800_000_000);
        setUpForge();

        hook = DrawdownCapHook(
            deployHookTo(
                "src/hooks/DrawdownCapHook.sol:DrawdownCapHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, DrawdownCapHook.Config(MAX_FALL, EPOCH));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-30000, 30000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function doSwap(bool zeroForOne, int256 amountSpecified) external {
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function _sellToLimit(int256 amount) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: hook.sqrtPriceLimitDownX96(poolId)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "DrawdownCap");
    }

    function test_firstEpochOpensAtTheOpeningPrice() public view {
        (int24 openTick, uint64 openedAt) = hook.epochOf(poolId);
        assertEq(openTick, 0);
        assertEq(openedAt, uint64(block.timestamp));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(hook.limitTick(poolId), -int24(int256(uint256(MAX_FALL))));
    }

    function test_initialize_withoutConfiguration_reverts() public {
        PoolKey memory unconfigured = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));
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

    function test_configure_zeroField_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));
        vm.expectRevert(DrawdownCapHook.InvalidConfig.selector);
        hook.configure(other, DrawdownCapHook.Config(0, EPOCH));
    }

    function test_aSmallFallIsAllowed() public {
        swap(poolKey, true, -1e17, ZERO_BYTES);
        (uint256 remaining,) = hook.headroom(poolId);
        assertGt(remaining, 0, "the pool has not used its whole allowance");
    }

    function test_aFallPastTheLimitReverts() public {
        vm.expectRevert();
        swap(poolKey, true, -6e18, ZERO_BYTES);
    }

    function test_sellingWithTheLimitAsPriceLimitFillsInstead() public {
        _sellToLimit(-6e18);
        assertGe(poolSqrtPrice(poolKey), hook.sqrtPriceLimitDownX96(poolId), "the pool stopped at the limit");
    }

    function test_buyingIsNeverRestricted() public {
        _sellToLimit(-6e18); // park the pool on its limit

        // Bids still clear at the limit, which is the point of an asymmetric cap.
        swap(poolKey, false, -3e18, ZERO_BYTES);
        assertGt(poolSqrtPrice(poolKey), hook.sqrtPriceLimitDownX96(poolId));
    }

    function test_ralliesDoNotRaiseTheLimitWithinAnEpoch() public {
        int24 limitBefore = hook.limitTick(poolId);
        swap(poolKey, false, -3e18, ZERO_BYTES);
        assertEq(hook.limitTick(poolId), limitBefore, "the reference is the epoch open, not a running high");
    }

    function test_theEpochRollsAndRestoresTheAllowance() public {
        _sellToLimit(-6e18);
        (uint256 exhausted,) = hook.headroom(poolId);
        assertEq(exhausted, 0, "the allowance is spent");

        vm.warp(block.timestamp + EPOCH);
        swap(poolKey, true, -1e15, ZERO_BYTES); // the first swap of the new epoch rolls the reference

        (uint256 restored, uint256 resetsAt) = hook.headroom(poolId);
        assertGt(restored, 0, "a new epoch grants a fresh allowance");
        assertEq(resetsAt, block.timestamp + EPOCH);
    }

    function test_theAllowanceDoesNotResetEarly() public {
        _sellToLimit(-6e18);

        vm.warp(block.timestamp + EPOCH - 1);
        vm.expectRevert();
        swap(poolKey, true, -1e18, ZERO_BYTES);
    }

    function test_liquidityCanLeaveAtTheLimit() public {
        _sellToLimit(-6e18);

        // Nobody is trapped by a limit-down epoch.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-30000, 30000, -5e18, bytes32(0)), ZERO_BYTES
        );
    }

    function test_limitPriceMatchesLimitTick() public view {
        assertEq(hook.sqrtPriceLimitDownX96(poolId), TickMath.getSqrtPriceAtTick(hook.limitTick(poolId)));
    }

    function testFuzz_theCapHoldsAcrossAnySequenceOfTrades(uint8 pattern) public {
        for (uint256 i = 0; i < 8; i++) {
            bool sell = (pattern >> (i % 8)) & 1 == 1;
            try this.doSwap(sell, -8e17) {} catch {}

            (, int24 tick,,) = manager.getSlot0(poolId);
            assertGe(tick, hook.limitTick(poolId), "the pool went below its limit");
        }
    }
}
