// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RetroRebateHook} from "src/hooks/RetroRebateHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract RetroRebateHookTest is ForgeTest {
    RetroRebateHook internal hook;
    PoolKey internal poolKey;

    uint160 internal constant FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint24 internal constant SKIM = 5_000; // 0.5% of each swap funds the rebate
    uint32 internal constant EPOCH = 1 days;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);

        hook = RetroRebateHook(
            deployHookTo(
                "src/hooks/RetroRebateHook.sol:RetroRebateHook", FLAGS, abi.encode(address(manager), SKIM, EPOCH)
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function _swapFor(address account, int256 amount) private {
        swap(poolKey, true, amount, abi.encode(account));
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "RetroRebate");
    }

    function test_epochsAreAlignedToAbsoluteTime() public view {
        assertEq(hook.epochAt(0), 0);
        assertEq(hook.epochAt(EPOCH - 1), 0);
        assertEq(hook.epochAt(EPOCH), 1);
        assertEq(hook.currentEpoch(), block.timestamp / EPOCH);
    }

    function test_swappingRecordsVolumeAndFundsThePot() public {
        uint256 epoch = hook.currentEpoch();
        _swapFor(alice, -1e17);

        assertGt(hook.volumeOf(epoch, alice), 0, "volume should be credited to the named account");
        assertEq(hook.totalVolume(epoch), hook.volumeOf(epoch, alice), "and be the whole of the epoch so far");
        assertGt(hook.pot0(epoch) + hook.pot1(epoch), 0, "the skim should have funded the pot");
    }

    function test_aSwapThatNamesNobodyCreditsTheRouter() public {
        uint256 epoch = hook.currentEpoch();
        swap(poolKey, true, -1e17, ZERO_BYTES);
        assertGt(hook.volumeOf(epoch, address(swapRouter)), 0, "an unnamed swap credits the router it came through");
    }

    function test_theRunningEpochPaysNothingYet() public {
        uint256 epoch = hook.currentEpoch();
        _swapFor(alice, -1e17);

        (uint256 a0, uint256 a1) = hook.claimable(epoch, alice);
        assertEq(a0 + a1, 0, "a provisional rebate is not a rebate");

        vm.expectRevert(abi.encodeWithSelector(RetroRebateHook.EpochNotClosed.selector, epoch));
        vm.prank(alice);
        hook.claim(epoch, alice);
    }

    function test_aClosedEpochPaysProRataByVolume() public {
        uint256 epoch = hook.currentEpoch();
        _swapFor(alice, -2e17);
        _swapFor(bob, -1e17);

        uint256 aliceVolume = hook.volumeOf(epoch, alice);
        uint256 bobVolume = hook.volumeOf(epoch, bob);
        // Not exactly 2x: the larger swap moves the price against itself, so its output is slightly
        // sublinear. The rebate is proportional to what was actually traded, not to what was asked for.
        assertApproxEqRel(aliceVolume, 2 * bobVolume, 5e16, "alice traded about twice as much");

        vm.warp(block.timestamp + EPOCH);

        (uint256 aliceOwed0, uint256 aliceOwed1) = hook.claimable(epoch, alice);
        (uint256 bobOwed0, uint256 bobOwed1) = hook.claimable(epoch, bob);
        assertGt(aliceOwed0 + aliceOwed1, bobOwed0 + bobOwed1, "more volume, more rebate");
        assertApproxEqRel(
            aliceOwed0 + aliceOwed1, 2 * (bobOwed0 + bobOwed1), 5e16, "and in proportion to what each traded"
        );
    }

    function test_claimingPaysOutAndCannotBeRepeated() public {
        uint256 epoch = hook.currentEpoch();
        _swapFor(alice, -2e17);
        vm.warp(block.timestamp + EPOCH);

        (uint256 owed0, uint256 owed1) = hook.claimable(epoch, alice);
        assertGt(owed0 + owed1, 0);

        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        vm.prank(alice);
        (uint256 got0, uint256 got1) = hook.claim(epoch, alice);
        assertEq(got0, owed0);
        assertEq(got1, owed1);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice) - before0, owed0, "currency0 arrived");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(alice) - before1, owed1, "currency1 arrived");

        vm.expectRevert(abi.encodeWithSelector(RetroRebateHook.AlreadyClaimed.selector, epoch));
        vm.prank(alice);
        hook.claim(epoch, alice);
    }

    function test_anAccountThatTradedNothingHasNothingToClaim() public {
        uint256 epoch = hook.currentEpoch();
        _swapFor(alice, -1e17);
        vm.warp(block.timestamp + EPOCH);

        vm.expectRevert(abi.encodeWithSelector(RetroRebateHook.NothingToClaim.selector, epoch));
        vm.prank(bob);
        hook.claim(epoch, bob);
    }

    function test_namingSomebodyElseGivesAwayYourOwnRebate() public {
        // The reason no signature is needed. Alice pays for the swap and names Bob; Bob gets the rebate. The only
        // thing a forged attribution achieves is a donation.
        uint256 epoch = hook.currentEpoch();
        _swapFor(bob, -1e17);
        vm.warp(block.timestamp + EPOCH);

        (uint256 bob0, uint256 bob1) = hook.claimable(epoch, bob);
        (uint256 alice0, uint256 alice1) = hook.claimable(epoch, alice);
        assertGt(bob0 + bob1, 0, "the named account holds the claim");
        assertEq(alice0 + alice1, 0, "and the payer holds none");
    }

    function test_epochsAreIndependent() public {
        uint256 first = hook.currentEpoch();
        _swapFor(alice, -1e17);

        vm.warp(block.timestamp + EPOCH);
        uint256 second = hook.currentEpoch();
        _swapFor(bob, -1e17);

        assertEq(hook.volumeOf(second, alice), 0, "a new epoch starts empty");
        assertGt(hook.volumeOf(first, alice), 0, "and the old one is untouched");
        assertGt(hook.pot0(second) + hook.pot1(second), 0, "with its own pot");
    }

    function test_theConstructorRejectsBadParameters() public {
        vm.expectRevert(RetroRebateHook.InvalidEpoch.selector);
        deployHookToNamespace(
            "src/hooks/RetroRebateHook.sol:RetroRebateHook", FLAGS, abi.encode(address(manager), SKIM, uint32(0)), 0xF111
        );

        vm.expectRevert(RetroRebateHook.SkimTooLarge.selector);
        deployHookToNamespace(
            "src/hooks/RetroRebateHook.sol:RetroRebateHook",
            FLAGS,
            abi.encode(address(manager), uint24(200_000), EPOCH),
            0xF222
        );
    }

    function testFuzz_theEpochPotIsNeverOverPaid(uint96 a, uint96 b) public {
        uint256 epoch = hook.currentEpoch();
        _swapFor(alice, -int256(bound(a, 1e15, 1e17)));
        _swapFor(bob, -int256(bound(b, 1e15, 1e17)));
        vm.warp(block.timestamp + EPOCH);

        (uint256 a0, uint256 a1) = hook.claimable(epoch, alice);
        (uint256 b0, uint256 b1) = hook.claimable(epoch, bob);
        assertLe(a0 + b0, hook.pot0(epoch), "the sum of claims can never exceed the pot");
        assertLe(a1 + b1, hook.pot1(epoch));
    }
}
