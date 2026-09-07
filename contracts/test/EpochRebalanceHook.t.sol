// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";

import {EpochRebalanceHook} from "src/hooks/EpochRebalanceHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract EpochRebalanceHookTest is ForgeTest {
    EpochRebalanceHook internal hook;
    PoolKey internal poolKey;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant FEE_BPS = 30;

    uint64 internal t0;
    uint64 internal t1;
    uint64 internal t2;

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);
        t0 = uint64(block.timestamp);
        t1 = uint64(block.timestamp + 30 days);
        t2 = uint64(block.timestamp + 90 days);

        hook = EpochRebalanceHook(deployHookTo("src/hooks/EpochRebalanceHook.sol:EpochRebalanceHook", FLAGS, _args()));

        poolKey = PoolKey(currency0, currency1, 0, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    /// @dev A glide from 80/20 down to 50/50 over a month, then flat to 30/70 over two more.
    function _args() private view returns (bytes memory) {
        EpochRebalanceHook.Checkpoint[] memory schedule = new EpochRebalanceHook.Checkpoint[](3);
        schedule[0] = EpochRebalanceHook.Checkpoint({time: t0, weight0Bps: 8_000});
        schedule[1] = EpochRebalanceHook.Checkpoint({time: t1, weight0Bps: 5_000});
        schedule[2] = EpochRebalanceHook.Checkpoint({time: t2, weight0Bps: 3_000});
        return abi.encode(address(manager), schedule, FEE_BPS, "Index LP", "IDX-LP");
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "EpochRebalance");
    }

    function test_theWholeScheduleIsPublic() public view {
        // The property the design turns on: a provider can read the pool's entire future before depositing.
        EpochRebalanceHook.Checkpoint[] memory schedule = hook.schedule();
        assertEq(schedule.length, 3);
        assertEq(schedule[0].weight0Bps, 8_000);
        assertEq(schedule[2].weight0Bps, 3_000);
        assertEq(hook.checkpointCount(), 3);
    }

    function test_theWeightGlidesLinearlyBetweenCheckpoints() public view {
        assertEq(hook.weightAtBps(t0), 8_000, "it starts where the schedule says");
        assertEq(hook.weightAtBps(t0 + 15 days), 6_500, "halfway through the first leg is halfway between");
        assertEq(hook.weightAtBps(t1), 5_000, "and lands on the checkpoint");
        assertEq(hook.weightAtBps(t1 + 30 days), 4_000, "the second leg glides down too");
        assertEq(hook.weightAtBps(t2), 3_000);
    }

    function test_theWeightIsFlatOutsideTheSchedule() public view {
        assertEq(hook.weightAtBps(t0 - 100 days), 8_000, "before the schedule it holds the first weight");
        assertEq(hook.weightAtBps(t2 + 1000 days), 3_000, "after it, the last");
    }

    function test_thereIsNoStep_soNoSingleBlockIsWorthRacingTo() public view {
        // Walk the whole glide a day at a time and assert the weight never jumps by more than one day's worth.
        // A stepped reconstitution would fail this, and that step is what index front-running trades against.
        uint256 previous = hook.weightAtBps(t0);
        uint256 maxDailyMove = ((8_000 - 5_000) * 1 days) / 30 days + 1;
        for (uint256 t = t0; t <= t2; t += 1 days) {
            uint256 current = hook.weightAtBps(t);
            uint256 step = current > previous ? current - previous : previous - current;
            assertLe(step, maxDailyMove, "the glide must never step");
            previous = current;
        }
    }

    function test_thePriceMovesWithTheScheduleWithNobodyTrading() public {
        // The rebalance is the schedule, not a trade: hold the reserves still and the pool re-prices itself.
        uint256 early = hook.spotPrice();
        vm.warp(t1);
        uint256 later = hook.spotPrice();
        assertLt(later, early, "as the target weight on currency0 falls, so does the price the pool asks for it");
    }

    function test_nobodyCanChangeTheSchedule() public view {
        // There is no setter, by construction. This asserts the shape of the contract rather than a behaviour: the
        // only way to alter the glide is to deploy a different pool.
        assertEq(hook.checkpointCount(), 3);
    }

    function test_aScheduleMustBeOrderedAndBounded() public {
        EpochRebalanceHook.Checkpoint[] memory backwards = new EpochRebalanceHook.Checkpoint[](2);
        backwards[0] = EpochRebalanceHook.Checkpoint({time: t1, weight0Bps: 5_000});
        backwards[1] = EpochRebalanceHook.Checkpoint({time: t0, weight0Bps: 6_000});
        vm.expectRevert(EpochRebalanceHook.InvalidSchedule.selector);
        deployHookToNamespace(
            "src/hooks/EpochRebalanceHook.sol:EpochRebalanceHook",
            FLAGS,
            abi.encode(address(manager), backwards, FEE_BPS, "x", "X"),
            0xAAAA
        );

        EpochRebalanceHook.Checkpoint[] memory extreme = new EpochRebalanceHook.Checkpoint[](1);
        extreme[0] = EpochRebalanceHook.Checkpoint({time: t0, weight0Bps: 9_900});
        vm.expectRevert(EpochRebalanceHook.InvalidSchedule.selector);
        deployHookToNamespace(
            "src/hooks/EpochRebalanceHook.sol:EpochRebalanceHook",
            FLAGS,
            abi.encode(address(manager), extreme, FEE_BPS, "x", "X"),
            0xBBBB
        );

        EpochRebalanceHook.Checkpoint[] memory empty = new EpochRebalanceHook.Checkpoint[](0);
        vm.expectRevert(EpochRebalanceHook.InvalidSchedule.selector);
        deployHookToNamespace(
            "src/hooks/EpochRebalanceHook.sol:EpochRebalanceHook",
            FLAGS,
            abi.encode(address(manager), empty, FEE_BPS, "x", "X"),
            0xCCCC
        );
    }

    function test_swapPaysExactlyTheQuote() public {
        uint256 quoted = hook.quote(true, true, 1e18);
        BalanceDelta delta = swap(poolKey, true, -1e18, ZERO_BYTES);
        assertEq(delta.amount0(), -1e18);
        assertEq(uint256(uint128(delta.amount1())), quoted, "output is exactly what was quoted");
    }

    function test_theInvariantIsNeverReducedByASwap() public {
        uint256 before = hook.invariant();
        swap(poolKey, true, -5e18, ZERO_BYTES);
        assertGe(hook.invariant(), before, "a swap must never reduce the invariant");
    }

    function testFuzz_theWeightIsAlwaysInsideTheScheduledBand(uint64 offset) public view {
        uint256 t = bound(offset, 0, 400 days);
        uint256 weight = hook.weightAtBps(t0 + t);
        assertLe(weight, 8_000, "never above the highest checkpoint");
        assertGe(weight, 3_000, "never below the lowest");
    }
}
