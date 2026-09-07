// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {LiquidityFloorHook} from "src/hooks/LiquidityFloorHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract LiquidityFloorHookTest is ForgeTest {
    LiquidityFloorHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint16 internal constant FLOOR_BPS = 3_000; // 30% committed
    uint64 internal unlockAt;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    uint256 internal constant ADD = 10 ether;

    function setUp() public {
        setUpForge();

        hook = LiquidityFloorHook(
            deployHookTo(
                "src/hooks/LiquidityFloorHook.sol:LiquidityFloorHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG,
                abi.encode(address(manager))
            )
        );

        unlockAt = uint64(block.timestamp + 90 days);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        hook.configure(poolKey, LiquidityFloorHook.Config({floorBps: FLOOR_BPS, unlockTimestamp: unlockAt}));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _position() private view returns (bytes32) {
        return hook.positionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    function _modify(int256 liquidityDelta) private {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "LiquidityFloor");
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

    function test_configure_rejectsBadParameters() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;

        vm.expectRevert(LiquidityFloorHook.InvalidFloor.selector);
        hook.configure(other, LiquidityFloorHook.Config({floorBps: 0, unlockTimestamp: unlockAt}));

        vm.expectRevert(LiquidityFloorHook.InvalidFloor.selector);
        hook.configure(other, LiquidityFloorHook.Config({floorBps: 10_001, unlockTimestamp: unlockAt}));

        vm.expectRevert(LiquidityFloorHook.UnlockInThePast.selector);
        hook.configure(
            other, LiquidityFloorHook.Config({floorBps: FLOOR_BPS, unlockTimestamp: uint64(block.timestamp)})
        );
    }

    function test_add_recordsCommitment() public {
        _modify(int256(ADD));
        bytes32 position = _position();
        assertEq(hook.addedLiquidity(poolId, position), ADD);
        assertEq(hook.committedLiquidity(poolId, position), ADD * FLOOR_BPS / 10_000);
        assertEq(hook.withdrawableLiquidity(poolId, position), ADD - ADD * FLOOR_BPS / 10_000);
    }

    function test_withdraw_uncommittedPortion_succeeds() public {
        _modify(int256(ADD));
        uint256 free = ADD - ADD * FLOOR_BPS / 10_000;
        _modify(-int256(free));
        assertEq(hook.removedLiquidity(poolId, _position()), free);
        assertEq(hook.withdrawableLiquidity(poolId, _position()), 0);
    }

    function test_withdraw_beyondCommitment_reverts() public {
        _modify(int256(ADD));
        uint256 committed = ADD * FLOOR_BPS / 10_000;
        uint256 free = ADD - committed;

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(LiquidityFloorHook.CommitmentBreached.selector, committed, committed - 1),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _modify(-int256(free + 1));
    }

    function test_afterUnlock_everythingIsWithdrawable() public {
        _modify(int256(ADD));
        vm.warp(unlockAt);
        assertEq(hook.committedLiquidity(poolId, _position()), 0);
        assertEq(hook.withdrawableLiquidity(poolId, _position()), ADD);
        _modify(-int256(ADD));
    }

    function test_toppingUp_raisesTheFloorProportionally_neverTrapsTheTopUp() public {
        _modify(int256(ADD));
        uint256 freeBefore = hook.withdrawableLiquidity(poolId, _position());

        _modify(int256(ADD));
        uint256 freeAfter = hook.withdrawableLiquidity(poolId, _position());

        // Adding a second identical tranche must free exactly as much again: the ratio the provider signed up for
        // is preserved, so topping up is never a one-way door.
        assertEq(freeAfter, freeBefore * 2, "top-up must preserve the free/committed ratio");
        assertEq(hook.committedLiquidity(poolId, _position()), 2 * ADD * FLOOR_BPS / 10_000);
    }

    function test_commitmentIsPerPosition_notPoolWide() public {
        // Two positions with different salts are independent commitments: one exiting cannot change what the
        // other may withdraw. This is the property that removes the bank-run race.
        _modify(int256(ADD));

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(ADD),
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );

        bytes32 second = hook.positionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(uint256(1)));
        uint256 secondFreeBefore = hook.withdrawableLiquidity(poolId, second);

        // Drain everything the first position may withdraw.
        _modify(-int256(hook.withdrawableLiquidity(poolId, _position())));

        assertEq(
            hook.withdrawableLiquidity(poolId, second),
            secondFreeBefore,
            "another position's exit must not change this position's allowance"
        );
    }

    function testFuzz_withdrawableNeverExceedsHeldMinusCommitted(uint96 add, uint96 remove) public {
        // Bounds are harness limits, not properties of the hook: v4-core's test router asserts that a withdrawal
        // moves a non-zero amount of at least one currency, so dust-sized removals trip it, and it asserts on its
        // own settlement accounting above roughly 1e18 of liquidity in this range.
        uint256 addAmount = bound(add, 1e10, 1e18);
        _modify(int256(addAmount));

        bytes32 position = _position();
        uint256 free = hook.withdrawableLiquidity(poolId, position);
        uint256 removeAmount = bound(remove, 1e6, free);
        _modify(-int256(removeAmount));

        assertEq(hook.withdrawableLiquidity(poolId, position), free - removeAmount);
        assertGe(
            hook.addedLiquidity(poolId, position) - hook.removedLiquidity(poolId, position),
            hook.committedLiquidity(poolId, position),
            "held liquidity must never fall below the commitment"
        );
    }
}
