// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CommitRevealDarkHook} from "src/hooks/CommitRevealDarkHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract CommitRevealDarkHookTest is ForgeTest {
    CommitRevealDarkHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    uint32 internal constant DELAY = 2;
    uint32 internal constant TTL = 50;
    uint128 internal constant BOND = 0.01 ether;

    int256 internal constant SIZE = -1e15;
    bytes32 internal constant SALT = keccak256("a secret nobody else has");

    address internal alice = address(0xA11CE);

    function setUp() public {
        setUpForge();
        vm.roll(1000);

        hook = CommitRevealDarkHook(
            deployHookTo("src/hooks/CommitRevealDarkHook.sol:CommitRevealDarkHook", FLAGS, abi.encode(address(manager)))
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(
            poolKey, CommitRevealDarkHook.Config({delayBlocks: DELAY, ttlBlocks: TTL, bond: BOND})
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );

        vm.deal(alice, 10 ether);
        vm.deal(address(this), 10 ether);
    }

    /**
     * @dev The hash for a sell of `amount` through the harness router, which pins the limit to MIN_PRICE_LIMIT.
     *
     * Always call this into a local before a `vm.prank` or `vm.expectRevert`: it is an external staticcall, so an
     * inline call would consume the cheatcode and silently test something else.
     */
    function _hashFor(int256 amount, bytes32 salt) internal view returns (bytes32) {
        return hook.commitmentHash(poolId, true, amount, MIN_PRICE_LIMIT, salt);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "CommitRevealDark");
    }

    function test_configure_rejectsAZeroDelay() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(CommitRevealDarkHook.InvalidDelay.selector);
        hook.configure(other, CommitRevealDarkHook.Config({delayBlocks: 0, ttlBlocks: TTL, bond: BOND}));
    }

    function test_configure_rejectsATtlInsideTheDelay() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(CommitRevealDarkHook.InvalidTtl.selector);
        hook.configure(other, CommitRevealDarkHook.Config({delayBlocks: 5, ttlBlocks: 5, bond: BOND}));
    }

    function test_anUnconfiguredPoolCannotBeInitialized() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_commitRequiresTheExactBond() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealDarkHook.WrongBond.selector, BOND));
        hook.commit{value: BOND - 1}(poolKey, c);
    }

    function test_aCommitmentCannotBeMadeTwice() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.startPrank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.expectRevert(CommitRevealDarkHook.AlreadyCommitted.selector);
        hook.commit{value: BOND}(poolKey, c);
        vm.stopPrank();
    }

    function test_anUncommittedSwapIsRefused() public {
        vm.expectRevert();
        swap(poolKey, true, SIZE, abi.encode(SALT));
    }

    function test_aCommittedSwapGoesThroughAfterTheDelay() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);

        vm.roll(block.number + DELAY);
        swap(poolKey, true, SIZE, abi.encode(SALT));

        (address owner,,) = hook.commitmentOf(_hashFor(SIZE, SALT));
        assertEq(owner, address(0), "commitment should be spent");
    }

    function test_revealingEarlyIsRefused() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);

        vm.roll(block.number + DELAY - 1);
        vm.expectRevert();
        swap(poolKey, true, SIZE, abi.encode(SALT));
    }

    /// @dev The property the whole hook exists for: a reaction placed after seeing the order cannot execute.
    function test_aSwapCommittedInTheSameBlockCannotExecute() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.roll(block.number + DELAY);

        // An attacker sees alice's reveal and commits their own trade in the very same block.
        bytes32 attackerSalt = keccak256("reaction");
        hook.commit{value: BOND}(poolKey, _hashFor(-5e14, attackerSalt));


        vm.expectRevert();
        swap(poolKey, true, -5e14, abi.encode(attackerSalt));

        // Alice's own, older commitment is unaffected.
        swap(poolKey, true, SIZE, abi.encode(SALT));
    }

    function test_aCommitmentIsGoodForExactlyOneSize() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.roll(block.number + DELAY);

        vm.expectRevert();
        swap(poolKey, true, SIZE - 1, abi.encode(SALT));
    }

    function test_aCommitmentIsGoodForExactlyOneDirection() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.roll(block.number + DELAY);

        vm.expectRevert();
        swap(poolKey, false, SIZE, abi.encode(SALT));
    }

    function test_theWrongSaltDoesNotReveal() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.roll(block.number + DELAY);

        vm.expectRevert();
        swap(poolKey, true, SIZE, abi.encode(keccak256("guess")));
    }

    function test_aCommitmentCannotBeSpentTwice() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.startPrank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.stopPrank();
        vm.roll(block.number + DELAY);

        swap(poolKey, true, SIZE, abi.encode(SALT));
        vm.expectRevert();
        swap(poolKey, true, SIZE, abi.encode(SALT));
    }

    function test_theBondComesBackToTheCommitterOnReveal() public {
        bytes32 c = _hashFor(SIZE, SALT);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        assertEq(alice.balance, before - BOND, "bond should be held");

        vm.roll(block.number + DELAY);
        swap(poolKey, true, SIZE, abi.encode(SALT));
        assertEq(alice.balance, before, "bond should be returned in full");
    }

    function test_revealingAfterTheTtlIsRefused() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);

        vm.roll(block.number + TTL + 1);
        vm.expectRevert();
        swap(poolKey, true, SIZE, abi.encode(SALT));
    }

    function test_anExpiredBondIsForfeitedToThePool() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);

        vm.roll(block.number + TTL + 1);
        hook.sweepExpired(poolKey, c);

        assertEq(hook.forfeited(poolId), BOND, "bond should accrue to the pool");
        (address owner,,) = hook.commitmentOf(c);
        assertEq(owner, address(0), "commitment should be gone");
    }

    function test_aLiveCommitmentCannotBeSwept() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);

        uint256 expiresAt = block.number + TTL;
        vm.roll(expiresAt);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealDarkHook.NotExpiredYet.selector, expiresAt));
        hook.sweepExpired(poolKey, c);
    }

    function test_forfeitedBondsCanBeDistributed() public {
        bytes32 c = _hashFor(SIZE, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.roll(block.number + TTL + 1);
        hook.sweepExpired(poolKey, c);

        address recipient = address(0xBEEF);
        hook.distributeForfeited(poolKey, recipient);
        assertEq(recipient.balance, BOND, "recipient should hold the forfeited bond");
        assertEq(hook.forfeited(poolId), 0, "pool balance should be cleared");
    }

    function test_distributingNothingReverts() public {
        vm.expectRevert(CommitRevealDarkHook.NothingToWithdraw.selector);
        hook.distributeForfeited(poolKey, address(0xBEEF));
    }

    /// @dev No size in a plausible range can be revealed without the salt that produced its commitment.
    function testFuzz_aCommitmentRevealsNothingWithoutItsSalt(uint256 magnitude, bytes32 guess) public {
        int256 amount = -int256(bound(magnitude, 1e12, 1e16));
        vm.assume(guess != SALT);

        bytes32 c = _hashFor(amount, SALT);
        vm.prank(alice);
        hook.commit{value: BOND}(poolKey, c);
        vm.roll(block.number + DELAY);

        vm.expectRevert();
        swap(poolKey, true, amount, abi.encode(guess));
    }

}
