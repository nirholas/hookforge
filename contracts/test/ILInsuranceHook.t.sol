// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILInsuranceHook} from "src/hooks/ILInsuranceHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract ILInsuranceHookTest is ForgeTest {
    ILInsuranceHook internal hook;
    PoolKey internal poolKey;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint24 internal constant PREMIUM = 5_000; // 0.5% of each swap funds the cover
    uint32 internal constant COVERAGE = 8_000; // 80% of a measured loss
    uint32 internal constant VESTING = 30 days;

    int24 internal constant LOWER = -60000;
    int24 internal constant UPPER = 60000;

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);

        hook = ILInsuranceHook(
            deployHookTo(
                "src/hooks/ILInsuranceHook.sol:ILInsuranceHook",
                FLAGS,
                abi.encode(address(manager), PREMIUM, COVERAGE, VESTING)
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _modify(int256 liquidity) private {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(LOWER, UPPER, liquidity, bytes32(0)), ZERO_BYTES
        );
    }

    function _position() private view returns (bytes32) {
        return hook.positionKey(address(modifyLiquidityRouter), LOWER, UPPER, bytes32(0));
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ILInsurance");
    }

    function test_theConstructorBoundsItsPromises() public {
        vm.expectRevert(ILInsuranceHook.CoverageTooLarge.selector);
        deployHookToNamespace(
            "src/hooks/ILInsuranceHook.sol:ILInsuranceHook",
            FLAGS,
            abi.encode(address(manager), PREMIUM, uint32(20_000), VESTING),
            0x1A1A
        );

        vm.expectRevert(ILInsuranceHook.PremiumTooLarge.selector);
        deployHookToNamespace(
            "src/hooks/ILInsuranceHook.sol:ILInsuranceHook",
            FLAGS,
            abi.encode(address(manager), uint24(200_000), COVERAGE, VESTING),
            0x2B2B
        );
    }

    function test_depositIsRecordedAsItActuallyHappened() public {
        _modify(1e19);
        (uint128 deposited0, uint128 deposited1, uint128 liquidity, uint64 openedAt) = hook.coverOf(_position());
        assertGt(deposited0, 0, "currency0 that went in should be recorded");
        assertGt(deposited1, 0, "and currency1");
        assertEq(liquidity, 1e19, "and the liquidity it holds");
        assertEq(openedAt, block.timestamp, "the vesting clock starts at the deposit");
    }

    function test_tradingFillsTheFund() public {
        _modify(1e19);
        assertEq(hook.fund0() + hook.fund1(), 0, "nothing before any trading");

        swap(poolKey, true, -1e17, ZERO_BYTES);
        assertGt(hook.fund0() + hook.fund1(), 0, "the premium should have funded the cover");
    }

    function test_coverVestsWithTimeHeld() public {
        _modify(1e19);
        assertEq(hook.vestedBps(_position()), 0, "a position that just arrived is covered for nothing");

        vm.warp(block.timestamp + VESTING / 2);
        assertApproxEqAbs(hook.vestedBps(_position()), 5_000, 2, "halfway through vesting is half covered");

        vm.warp(block.timestamp + VESTING);
        assertEq(hook.vestedBps(_position()), 10_000, "and fully covered after the term");
    }

    function test_aPositionThatDidNotLoseIsPaidNothing() public {
        _modify(1e19);
        vm.warp(block.timestamp + VESTING);

        // Withdrawing at the same price it entered at: nothing diverged, so there is nothing to cover.
        (uint256 claim,,) = hook.quoteClaim(_position(), 1e18, 1e18);
        assertEq(claim, 0, "no divergence, no claim");
    }

    function test_aMeasuredLossProducesAClaimBoundedByTheFund() public {
        _modify(1e19);
        // Fill the fund with real trading.
        for (uint256 i = 0; i < 5; i++) {
            swap(poolKey, i % 2 == 0, -5e17, ZERO_BYTES);
        }
        assertGt(hook.fund1(), 0, "the fund should hold something");
        vm.warp(block.timestamp + VESTING);

        // A withdrawal returning materially less than went in, valued at the current price.
        (uint128 deposited0, uint128 deposited1,,) = hook.coverOf(_position());
        (uint256 claim, uint256 heldValue, uint256 positionValue) =
            hook.quoteClaim(_position(), deposited0 / 2, deposited1 / 2);

        assertGt(heldValue, positionValue, "the comparison should show a loss");
        assertGt(claim, 0, "which should produce a claim");
        assertLe(claim, hook.fund1(), "and the fund never pays more than it holds");
    }

    function test_theFundNeverPaysMoreThanItHolds() public {
        _modify(1e19);
        vm.warp(block.timestamp + VESTING);

        // No trading at all, so the fund is empty. Even a catastrophic loss pays nothing, which is the honest
        // behaviour of a fund rather than a promise it cannot keep.
        assertEq(hook.fund1(), 0);
        (uint256 claim,,) = hook.quoteClaim(_position(), 0, 0);
        assertEq(claim, 0, "an empty fund pays nothing");
    }

    function test_withdrawingPaysTheClaimAndShrinksTheFund() public {
        _modify(1e19);
        for (uint256 i = 0; i < 6; i++) {
            swap(poolKey, i % 2 == 0, -8e17, ZERO_BYTES);
        }
        vm.warp(block.timestamp + VESTING);

        uint256 fundBefore = hook.fund1();
        assertGt(fundBefore, 0);

        _modify(-1e19);

        assertLe(hook.fund1(), fundBefore, "the fund can only shrink when it pays");
        assertEq(hook.fund1() + hook.paidOut1(), fundBefore, "everything that left the fund was paid out");
    }

    function test_aFullyExitedPositionResetsItsClock() public {
        _modify(1e19);
        vm.warp(block.timestamp + VESTING);
        _modify(-1e19);

        (uint128 deposited0, uint128 deposited1, uint128 liquidity, uint64 openedAt) = hook.coverOf(_position());
        assertEq(liquidity, 0, "the position holds no liquidity");
        assertEq(deposited0, 0, "and no recorded deposit, not even the wei rounding leaves behind");
        assertEq(deposited1, 0);
        assertEq(openedAt, 0, "so it starts its cover again if it comes back");
    }

    function testFuzz_aClaimNeverExceedsTheCoverageShareOfTheLoss(uint96 out0, uint96 out1) public {
        _modify(1e19);
        for (uint256 i = 0; i < 4; i++) swap(poolKey, i % 2 == 0, -5e17, ZERO_BYTES);
        vm.warp(block.timestamp + VESTING);

        (uint256 claim, uint256 heldValue, uint256 positionValue) =
            hook.quoteClaim(_position(), bound(out0, 0, 1e18), bound(out1, 0, 1e18));

        if (positionValue >= heldValue) {
            assertEq(claim, 0);
        } else {
            uint256 loss = heldValue - positionValue;
            assertLe(claim, (loss * COVERAGE) / 10_000, "never more than the covered share of the loss");
            assertLe(claim, hook.fund1(), "and never more than the fund holds");
        }
    }
}
