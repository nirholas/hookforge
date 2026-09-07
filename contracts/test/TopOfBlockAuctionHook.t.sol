// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {TopOfBlockAuctionHook} from "src/hooks/TopOfBlockAuctionHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract TopOfBlockAuctionHookTest is ForgeTest {
    TopOfBlockAuctionHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    uint32 internal constant LEAD = 1;
    uint128 internal constant MIN_BID = 0.001 ether;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.roll(1000);

        hook = TopOfBlockAuctionHook(
            deployHookTo("src/hooks/TopOfBlockAuctionHook.sol:TopOfBlockAuctionHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, TopOfBlockAuctionHook.Config({leadBlocks: LEAD, minBid: MIN_BID}));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "TopOfBlockAuction");
    }

    function test_configure_rejectsAZeroLead() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(TopOfBlockAuctionHook.InvalidLead.selector);
        hook.configure(other, TopOfBlockAuctionHook.Config({leadBlocks: 0, minBid: MIN_BID}));
    }

    function test_aBidMustTargetAFutureBlock() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TopOfBlockAuctionHook.BlockTooSoon.selector, block.number + LEAD));
        hook.bid{value: 1 ether}(poolKey, block.number);
    }

    function test_theHighestBidStandsAndTheLoserIsRefundedInFull() public {
        uint256 target = block.number + LEAD;

        vm.prank(alice);
        hook.bid{value: 1 ether}(poolKey, target);

        vm.prank(bob);
        hook.bid{value: 2 ether}(poolKey, target);

        (address winner, uint128 amount) = hook.winnerOf(poolId, target);
        assertEq(winner, bob, "the higher bid stands");
        assertEq(amount, 2 ether);

        // Losing costs nothing but gas.
        assertEq(hook.refunds(alice), 1 ether, "the outbid party keeps their money");
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.withdrawRefund();
        assertEq(alice.balance - before, 1 ether, "and can take it back in full");
    }

    function test_aLowerBidIsRefused() public {
        uint256 target = block.number + LEAD;
        vm.prank(bob);
        hook.bid{value: 2 ether}(poolKey, target);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TopOfBlockAuctionHook.BidTooLow.selector, 2 ether));
        hook.bid{value: 1 ether}(poolKey, target);
    }

    function test_aBidBelowTheMinimumIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TopOfBlockAuctionHook.BidTooLow.selector, MIN_BID));
        hook.bid{value: MIN_BID - 1}(poolKey, block.number + LEAD);
    }

    function test_theWinnerGetsTheFirstSlotAndEveryoneElseWaits() public {
        uint256 target = block.number + LEAD;
        vm.prank(bob);
        hook.bid{value: 2 ether}(poolKey, target);

        vm.roll(target);

        // The router is what the hook sees as the sender, so the bid has to name it for this test to be about the
        // mechanism rather than about routing.
        vm.expectRevert();
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_theWinnerTakesTheSlotAndTheProceedsAccrueToThePool() public {
        uint256 target = block.number + LEAD;

        // Bid as the router, which is the account the hook sees.
        vm.deal(address(swapRouter), 5 ether);
        vm.prank(address(swapRouter));
        hook.bid{value: 2 ether}(poolKey, target);

        vm.roll(target);
        assertEq(hook.proceeds(poolId), 0);

        swap(poolKey, true, -1e15, ZERO_BYTES);

        assertTrue(hook.slotTaken(poolId, target), "the slot should be spent");
        assertEq(hook.proceeds(poolId), 2 ether, "and the bid should have accrued to the pool");
    }

    function test_afterTheSlotIsTakenThePoolIsOrdinary() public {
        uint256 target = block.number + LEAD;
        vm.deal(address(swapRouter), 5 ether);
        vm.prank(address(swapRouter));
        hook.bid{value: 2 ether}(poolKey, target);

        vm.roll(target);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        // A second swap in the same block is unrestricted: only the first slot was sold.
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_aBlockWithNoBidBehavesLikeAPoolWithNoHook() public {
        vm.roll(block.number + 5);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(hook.proceeds(poolId), 0, "nothing was sold, so nothing accrued");
    }

    function test_proceedsCanBeDistributed() public {
        uint256 target = block.number + LEAD;
        vm.deal(address(swapRouter), 5 ether);
        vm.prank(address(swapRouter));
        hook.bid{value: 2 ether}(poolKey, target);

        vm.roll(target);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        uint256 before = alice.balance;
        hook.distribute(poolKey, alice);
        assertEq(alice.balance - before, 2 ether, "the proceeds went where they were sent");
        assertEq(hook.proceeds(poolId), 0);

        vm.expectRevert(TopOfBlockAuctionHook.NothingToWithdraw.selector);
        hook.distribute(poolKey, alice);
    }

    function testFuzz_theStandingWinnerIsAlwaysTheHighestBidder(uint96 a, uint96 b) public {
        uint256 first = bound(a, MIN_BID, 5 ether);
        uint256 second = bound(b, MIN_BID, 5 ether);
        uint256 target = block.number + LEAD;

        vm.prank(alice);
        hook.bid{value: first}(poolKey, target);

        vm.prank(bob);
        if (second > first) {
            hook.bid{value: second}(poolKey, target);
            (address winner,) = hook.winnerOf(poolId, target);
            assertEq(winner, bob);
            assertEq(hook.refunds(alice), first, "the loser is always made whole");
        } else {
            vm.expectRevert(abi.encodeWithSelector(TopOfBlockAuctionHook.BidTooLow.selector, first));
            hook.bid{value: second}(poolKey, target);
        }
    }
}
