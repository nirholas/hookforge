// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BlockReversalHook} from "src/hooks/BlockReversalHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {Vm} from "forge-std/Test.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";

contract BlockReversalHookTest is ForgeTest {
    BlockReversalHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    uint24 internal constant BASE_FEE = 500; // 0.05%
    uint24 internal constant MAX_SURCHARGE = 9_500; // up to 1.00% in total
    int24 internal constant THRESHOLD = 20;
    int24 internal constant HALF_POINT = 60;

    function setUp() public {
        setUpForge();
        vm.roll(1000);

        hook = BlockReversalHook(
            deployHookTo("src/hooks/BlockReversalHook.sol:BlockReversalHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(
            poolKey,
            BlockReversalHook.Config({
                baseFee: BASE_FEE,
                maxSurcharge: MAX_SURCHARGE,
                thresholdTicks: THRESHOLD,
                halfPointTicks: HALF_POINT
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-24000, 24000, 5e19, bytes32(0)), ZERO_BYTES
        );
    }

    /// @dev The fee an override hook charges is never written to the pool, so the event is where it is read from.
    function _feeCharged() private returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Priced(bytes32,bool,int24,uint24)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (,, fee) = abi.decode(logs[i].data, (bool, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no fee was priced");
    }

    /// @dev Swaps and returns what the swap was actually charged.
    function _swapAndReadFee(bool zeroForOne, int256 amount) private returns (uint24) {
        vm.recordLogs();
        swap(poolKey, zeroForOne, amount, ZERO_BYTES);
        return _feeCharged();
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "BlockReversal");
    }

    // --- configuration ------------------------------------------------------

    function test_configure_rejectsAFeeAboveTheProtocolCeiling() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(BlockReversalHook.FeeTooLarge.selector);
        hook.configure(
            other,
            BlockReversalHook.Config({
                baseFee: 900_000,
                maxSurcharge: 200_000,
                thresholdTicks: THRESHOLD,
                halfPointTicks: HALF_POINT
            })
        );
    }

    function test_configure_rejectsAZeroThreshold() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(BlockReversalHook.InvalidThreshold.selector);
        hook.configure(
            other,
            BlockReversalHook.Config({
                baseFee: BASE_FEE,
                maxSurcharge: MAX_SURCHARGE,
                thresholdTicks: 0,
                halfPointTicks: HALF_POINT
            })
        );
    }

    function test_anUnconfiguredPoolCannotBeInitialized() public {
        PoolKey memory other =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // --- the quiet case -----------------------------------------------------

    function test_aQuietBlockChargesTheBaseFeeBothWays() public view {
        assertEq(hook.quoteFee(poolKey, true), BASE_FEE, "selling currency0");
        assertEq(hook.quoteFee(poolKey, false), BASE_FEE, "and buying it");
    }

    function test_theFirstSwapOfABlockPaysTheBaseFee() public {
        assertEq(_swapAndReadFee(true, -1e18), BASE_FEE, "nothing to unwind yet");
    }

    /// @dev The published quote has to be the fee the swap is actually charged, or it is decoration.
    function test_theQuoteMatchesWhatTheSwapPays() public {
        swap(poolKey, false, -5e18, ZERO_BYTES);
        uint24 quoted = hook.quoteFee(poolKey, true);
        assertGt(quoted, BASE_FEE, "sanity: this swap is being surcharged");
        assertEq(_swapAndReadFee(true, -1e18), quoted, "quote and charge must agree");
    }

    function test_aSmallMoveIsBelowTheThresholdAndNotCharged() public {
        swap(poolKey, true, -1e14, ZERO_BYTES);
        // The move is inside the threshold, so even the opposite direction is base rate.
        assertEq(hook.quoteFee(poolKey, false), BASE_FEE, "a move this small is not worth attacking");
    }

    // --- the mechanism ------------------------------------------------------

    /// @dev The property the hook exists for: the leg that closes the position pays, the one that opened it does not.
    function test_unwindingTheBlocksMoveCostsMoreThanMakingIt() public {
        swap(poolKey, false, -5e18, ZERO_BYTES); // pushes the tick up

        uint24 continuing = hook.quoteFee(poolKey, false);
        uint24 unwinding = hook.quoteFee(poolKey, true);

        assertEq(continuing, BASE_FEE, "pushing the price further is not unwinding anything");
        assertGt(unwinding, BASE_FEE, "coming back is");
    }

    function test_theSurchargeGrowsWithTheMoveBeingUnwound() public {
        swap(poolKey, false, -2e18, ZERO_BYTES);
        uint24 small = hook.quoteFee(poolKey, true);

        swap(poolKey, false, -20e18, ZERO_BYTES);
        uint24 large = hook.quoteFee(poolKey, true);

        assertGt(large, small, "a bigger move is a bigger unwind");
        assertLe(large, BASE_FEE + MAX_SURCHARGE, "and still inside the cap");
    }

    function test_theSurchargeIsCapped() public {
        swap(poolKey, false, -200e18, ZERO_BYTES);
        assertLe(hook.quoteFee(poolKey, true), BASE_FEE + MAX_SURCHARGE, "never above the configured ceiling");
    }

    /// @dev A sandwich pays; the swap it wrapped does not.
    function test_theSandwichedSwapIsNotTheOneCharged() public {
        // Attacker's opening leg, pushing the price up.
        assertEq(_swapAndReadFee(false, -5e18), BASE_FEE, "the open pays base rate");

        // The victim, trading the same way the attacker pushed.
        assertEq(_swapAndReadFee(false, -1e18), BASE_FEE, "and so does the victim");

        // The attacker's close.
        assertGt(_swapAndReadFee(true, -5e18), BASE_FEE, "the close is the leg that pays");
    }

    function test_itWorksInBothDirections() public {
        swap(poolKey, true, -5e18, ZERO_BYTES); // pushes the tick down
        assertEq(hook.quoteFee(poolKey, true), BASE_FEE, "continuing down is free");
        assertGt(hook.quoteFee(poolKey, false), BASE_FEE, "coming back up is not");
    }

    // --- block boundaries ---------------------------------------------------

    function test_aNewBlockOpensWhereTheLastOneClosed() public {
        swap(poolKey, false, -5e18, ZERO_BYTES);
        assertGt(hook.quoteFee(poolKey, true), BASE_FEE, "charged inside the block");

        vm.roll(block.number + 1);
        assertEq(hook.quoteFee(poolKey, true), BASE_FEE, "and forgotten in the next one");
    }

    /// @dev A two-block sandwich is not what this catches, and the docs say so. The test pins that down.
    function test_aSandwichSplitAcrossBlocksIsNotCharged() public {
        swap(poolKey, false, -5e18, ZERO_BYTES);
        vm.roll(block.number + 1);
        assertEq(_swapAndReadFee(true, -5e18), BASE_FEE, "the stated limitation, held to");
    }

    /// @dev Unwinding partly and then unwinding more must still be charged against the block's full excursion.
    function test_aPartialUnwindIsStillMeasuredAgainstTheFullMove() public {
        swap(poolKey, false, -20e18, ZERO_BYTES);
        uint24 first = hook.quoteFee(poolKey, true);

        swap(poolKey, true, -2e18, ZERO_BYTES);
        uint24 second = hook.quoteFee(poolKey, true);

        assertGt(first, BASE_FEE, "sanity: there was something to unwind");
        assertEq(second, first, "the rest of the unwind is priced against the same excursion");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev However the block moved, a swap continuing that move is never surcharged.
    function testFuzz_continuingTheMoveIsNeverSurcharged(uint256 size, bool up) public {
        size = bound(size, 1e15, 40e18);
        swap(poolKey, !up, -int256(size), ZERO_BYTES);
        assertEq(hook.quoteFee(poolKey, !up), BASE_FEE, "the direction the block is already going is base rate");
    }

    /// @dev And the fee is always a real, in-range LP fee whatever happened.
    function testFuzz_theFeeStaysInsideItsBand(uint256 size, bool up) public {
        size = bound(size, 1e15, 60e18);
        swap(poolKey, !up, -int256(size), ZERO_BYTES);

        uint24 fee = hook.quoteFee(poolKey, up);
        assertGe(fee, BASE_FEE, "never below the base rate");
        assertLe(fee, BASE_FEE + MAX_SURCHARGE, "never above the cap");
    }
}
