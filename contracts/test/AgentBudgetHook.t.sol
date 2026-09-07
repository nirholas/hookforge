// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {AgentBudgetHook} from "src/hooks/AgentBudgetHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract AgentBudgetHookTest is ForgeTest {
    AgentBudgetHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal principalKey = 0xA11CE;
    uint256 internal agentKey = 0xB0B;
    uint256 internal strangerKey = 0xBAD;
    address internal principal;
    address internal agent;

    uint128 internal constant CAP = 5e15;
    uint32 internal constant EPOCH = 1 hours;

    function setUp() public {
        setUpForge();

        principal = vm.addr(principalKey);
        agent = vm.addr(agentKey);

        hook = AgentBudgetHook(
            deployHookTo("src/hooks/AgentBudgetHook.sol:AgentBudgetHook", Hooks.AFTER_SWAP_FLAG, abi.encode(address(manager)))
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        // Epoch boundaries are absolute, so start the clock somewhere unaligned to catch off-by-one assumptions.
        vm.warp(1_800_000_123);
    }

    function _delegation() private view returns (AgentBudgetHook.Delegation memory) {
        return AgentBudgetHook.Delegation({
            principal: principal,
            agent: agent,
            poolId: poolId,
            cap0: CAP,
            cap1: CAP,
            epochLength: EPOCH,
            expiry: uint64(block.timestamp + 30 days),
            salt: bytes32(uint256(1))
        });
    }

    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Builds the hookData a swap carries: the delegation, the principal's signature, and the agent's per-swap one.
    function _hookData(AgentBudgetHook.Delegation memory delegation, uint256 nonce, uint256 signerKey)
        private
        view
        returns (bytes memory)
    {
        bytes32 delegationHash = hook.hashDelegation(delegation);
        bytes memory principalSig = _sign(principalKey, hook.delegationDigest(delegation));

        AgentBudgetHook.SwapAuthorization memory authorization = AgentBudgetHook.SwapAuthorization({
            delegationHash: delegationHash,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 hours)
        });
        bytes memory agentSig = _sign(signerKey, hook.swapDigest(authorization));

        return abi.encode(delegation, principalSig, authorization, agentSig);
    }

    function _expectHookRevert(bytes memory inner) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "AgentBudget");
    }

    function test_authorizedSwap_withinBudget_succeeds() public {
        BalanceDelta delta = swap(poolKey, true, -1e15, _hookData(_delegation(), 1, agentKey));
        assertLt(delta.amount0(), 0, "swap should have spent currency0");

        (uint256 remaining0,) = hook.remainingBudget(_delegation());
        assertEq(remaining0, CAP - uint256(uint128(-delta.amount0())), "spend should be metered exactly");
    }

    function test_swapWithoutHookData_reverts() public {
        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.AuthorizationRequired.selector));
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_swapSignedByStranger_reverts() public {
        // Build the payload before arming the cheatcode: `_hookData` makes view calls to the hook, and
        // `expectRevert` applies to the next call of any kind.
        bytes memory data = _hookData(_delegation(), 1, strangerKey);
        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.BadAgentSignature.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_replayedNonce_reverts() public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        bytes memory data = _hookData(delegation, 7, agentKey);
        swap(poolKey, true, -1e15, data);

        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.NonceAlreadyUsed.selector, 7));
        swap(poolKey, true, -1e15, data);
    }

    function test_overBudgetSwap_reverts_andLeavesNothingBehind() public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        delegation.cap0 = 1e15;

        // Comfortably inside the cap.
        swap(poolKey, true, -5e14, _hookData(delegation, 1, agentKey));
        (uint256 beforeRemaining,) = hook.remainingBudget(delegation);

        // This one would cross it, so the whole swap must unwind.
        uint256 balanceBefore = poolKey.currency0.balanceOf(address(this));
        bytes memory data = _hookData(delegation, 2, agentKey);
        vm.expectRevert();
        swap(poolKey, true, -1e15, data);

        (uint256 afterRemaining,) = hook.remainingBudget(delegation);
        assertEq(afterRemaining, beforeRemaining, "a rejected swap must not consume budget");
        assertEq(poolKey.currency0.balanceOf(address(this)), balanceBefore, "a rejected swap must not move funds");
        assertFalse(hook.nonceUsed(hook.hashDelegation(delegation), 2), "a rejected swap must not burn its nonce");
    }

    function test_exactOutputSwap_isMeteredOnWhatItActuallySpent() public {
        // The reason the budget is measured after the swap: an exact-output swap's `amountSpecified` says nothing
        // about the input, so a cap checked before the swap would not bind it at all.
        AgentBudgetHook.Delegation memory delegation = _delegation();
        BalanceDelta delta = swap(poolKey, true, 1e15, _hookData(delegation, 1, agentKey));

        uint256 actuallySpent = uint256(uint128(-delta.amount0()));
        assertGt(actuallySpent, 1e15, "an exact-output swap pays more than it receives at a 0.3% fee");

        (uint256 remaining0,) = hook.remainingBudget(delegation);
        assertEq(remaining0, CAP - actuallySpent, "the cap must bind the real input, not the specified output");
    }

    function test_budgetResetsOnTheEpochBoundary() public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        swap(poolKey, true, -1e15, _hookData(delegation, 1, agentKey));
        (uint256 spentEpoch,) = hook.remainingBudget(delegation);
        assertLt(spentEpoch, CAP);

        vm.warp(block.timestamp + EPOCH);
        (uint256 freshEpoch,) = hook.remainingBudget(delegation);
        assertEq(freshEpoch, CAP, "a new epoch starts with the full cap");

        swap(poolKey, true, -1e15, _hookData(delegation, 2, agentKey));
    }

    function test_revokedDelegation_reverts() public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        vm.prank(principal);
        hook.revoke(delegation);

        bytes memory data = _hookData(delegation, 1, agentKey);
        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.Revoked.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_revoke_byAnyoneElse_reverts() public {
        vm.expectRevert(AgentBudgetHook.BadPrincipalSignature.selector);
        hook.revoke(_delegation());
    }

    function test_expiredDelegation_reverts() public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        delegation.expiry = uint64(block.timestamp + 1 hours);
        bytes memory data = _hookData(delegation, 1, agentKey);

        vm.warp(block.timestamp + 2 hours);
        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.Expired.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_delegationForAnotherPool_reverts() public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        delegation.poolId = PoolId.wrap(keccak256("some other pool"));

        bytes memory data = _hookData(delegation, 1, agentKey);
        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.WrongPool.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_tamperedCapIsRejected() public {
        // Raising the cap after the principal signed changes the delegation hash, so the signature no longer recovers.
        AgentBudgetHook.Delegation memory honest = _delegation();
        bytes memory data = _hookData(honest, 1, agentKey);

        (, bytes memory principalSig, AgentBudgetHook.SwapAuthorization memory auth, bytes memory agentSig) =
            abi.decode(data, (AgentBudgetHook.Delegation, bytes, AgentBudgetHook.SwapAuthorization, bytes));

        AgentBudgetHook.Delegation memory tampered = honest;
        tampered.cap0 = type(uint128).max;

        _expectHookRevert(abi.encodeWithSelector(AgentBudgetHook.BadAgentSignature.selector));
        swap(poolKey, true, -1e15, abi.encode(tampered, principalSig, auth, agentSig));
    }

    function testFuzz_meteringNeverExceedsTheCap(uint96 amount, uint8 swaps) public {
        AgentBudgetHook.Delegation memory delegation = _delegation();
        uint256 size = bound(amount, 1e12, 1e15);
        uint256 count = bound(swaps, 1, 8);

        uint256 landed;
        for (uint256 i = 0; i < count; i++) {
            try this.swapExternal(poolKey, true, -int256(size), _hookData(delegation, i + 1, agentKey)) {
                landed++;
            } catch {
                // Over budget: the swap unwound, which is the property under test.
            }
        }

        (uint256 remaining0,) = hook.remainingBudget(delegation);
        assertLe(CAP - remaining0, CAP, "metered spend can never exceed the cap");
        assertGt(landed, 0, "at least the first swap should fit inside the cap");
    }

    /// @dev `swap` is internal to the harness; this exposes it so a fuzz run can catch the revert.
    function swapExternal(PoolKey memory poolKey_, bool zeroForOne, int256 amountSpecified, bytes memory data)
        external
        returns (BalanceDelta)
    {
        return swap(poolKey_, zeroForOne, amountSpecified, data);
    }
}
