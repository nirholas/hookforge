// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ForgeHook} from "../base/ForgeHook.sol";

/**
 * @title AgentBudgetHook
 * @notice A spending limit the venue itself enforces: an autonomous agent may swap on this pool only within a budget
 * its principal signed, and the pool refuses the swap that would exceed it.
 *
 * @dev Handing a key to an autonomous agent means choosing between two bad options. Approve a router for a small
 * amount and the agent stalls the moment it needs more, at which point somebody has to be awake to raise it. Approve
 * it for the usual unbounded amount and the only thing standing between a bug and the whole balance is the agent's own
 * code, which is the thing you were trying not to trust.
 *
 * Smart accounts answer this with a policy engine, which works and costs you a smart account: a migration, a new
 * address, a new set of integrations, and a policy layer that every venue has to be taught about. This hook puts the
 * limit somewhere neither of those touch, in the pool, where it applies to any wallet, any router and any account
 * type, because it is enforced by the venue rather than by the spender.
 *
 * A principal signs one `Delegation`, off-chain and once: an agent address, a per-epoch cap in each of the pool's two
 * currencies, an epoch length, an expiry. The agent then signs each swap it makes under that delegation. On
 * `afterSwap` the hook checks both signatures, measures what the swap actually spent from the balance delta, and
 * reverts if that would take the agent past its cap for the current epoch. A revert in `afterSwap` unwinds the swap
 * with it, so an over-budget trade cannot land.
 *
 * Measuring in `afterSwap` rather than `beforeSwap` is deliberate and is what makes the cap honest. Before the swap
 * the only figure available is `amountSpecified`, which on an exact-output swap says nothing about how much the
 * swapper will actually pay; a budget checked against it would be trivially evaded by asking for an exact output and
 * letting the input land wherever the curve puts it. After the swap the true spend is in the delta.
 *
 * What this does not do, stated plainly, because the distinction matters: it never custodies funds, never moves a
 * token, and grants no allowance. The agent still needs its own ERC-20 approval to trade at all. The hook only
 * refuses to let this pool be the venue for a swap outside the budget. An agent with an unbounded approval can still
 * spend elsewhere, so this is a limit on a venue, not on a key, and it is worth exactly as much as the set of venues
 * that enforce it.
 *
 * Both signatures are checked with ERC-1271 as well as ECDSA, so a principal or an agent may itself be a contract.
 *
 * @custom:slug agent-budget
 * @custom:family Agent-native
 * @custom:prior-art Per-agent policy engines exist in smart-account land (session keys, ERC-7710 delegations, module-based spending limits), and hooks that gate swaps on an allowlist or a credential are common. Enforcing a signed, per-epoch, per-currency spending cap inside the AMM, on behalf of an EOA principal with no smart account anywhere in the path, is the contribution here.
 * @custom:limitation The cap binds this pool only. An agent holding an unbounded ERC-20 approval can spend the same funds on any venue that does not enforce the delegation, so this raises the cost of a compromised agent rather than bounding it absolutely. It also requires the caller to pass hookData, so an aggregator that strips it will simply be unable to trade the pool.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract AgentBudgetHook is ForgeHook, EIP712 {
    /// @notice A principal's standing authorisation for one agent on one pool.
    struct Delegation {
        /// @notice The account whose funds the agent spends, and the signer of this delegation.
        address principal;
        /// @notice The account permitted to swap under it.
        address agent;
        /// @notice The pool this delegation is valid on. A delegation never crosses pools.
        PoolId poolId;
        /// @notice Maximum `currency0` the agent may spend per epoch.
        uint128 cap0;
        /// @notice Maximum `currency1` the agent may spend per epoch.
        uint128 cap1;
        /// @notice Epoch length in seconds. Budgets reset on the boundary, they do not roll over.
        uint32 epochLength;
        /// @notice Timestamp after which the delegation is dead.
        uint64 expiry;
        /// @notice Distinguishes two otherwise identical delegations, and lets one be revoked without the other.
        bytes32 salt;
    }

    /// @notice One swap the agent authorises under a delegation.
    struct SwapAuthorization {
        bytes32 delegationHash;
        uint256 nonce;
        uint64 deadline;
    }

    bytes32 private constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address principal,address agent,bytes32 poolId,uint128 cap0,uint128 cap1,uint32 epochLength,uint64 expiry,bytes32 salt)"
    );

    bytes32 private constant SWAP_AUTHORIZATION_TYPEHASH =
        keccak256("SwapAuthorization(bytes32 delegationHash,uint256 nonce,uint64 deadline)");

    /// @notice Spend recorded against a delegation for the epoch currently in progress.
    struct Usage {
        uint64 epochStart;
        uint128 spent0;
        uint128 spent1;
    }

    /// @notice Per-delegation spend for the current epoch.
    mapping(bytes32 => Usage) public usageOf;

    /// @notice Nonces already consumed, per delegation. A nonce is single use.
    mapping(bytes32 => mapping(uint256 => bool)) public nonceUsed;

    /// @notice Delegations the principal has revoked. Revocation is permanent and immediate.
    mapping(bytes32 => bool) public revoked;

    /// @dev The swap carried no `hookData`, so there was no delegation to check it against.
    error AuthorizationRequired();

    /// @dev The delegation is for a different pool than the one being swapped.
    error WrongPool();

    /// @dev The delegation has expired, or the swap authorisation has.
    error Expired();

    /// @dev The principal has revoked this delegation.
    error Revoked();

    /// @dev The delegation signature does not recover to the named principal.
    error BadPrincipalSignature();

    /// @dev The swap signature does not recover to the delegation's agent.
    error BadAgentSignature();

    /// @dev This nonce has already been spent under this delegation.
    error NonceAlreadyUsed(uint256 nonce);

    /// @dev `epochLength` of zero would make every swap its own epoch, which is no budget at all.
    error InvalidEpochLength();

    /**
     * @dev The swap would take the agent past its budget for the epoch in progress.
     * @param currency 0 or 1, identifying which of the pool's currencies the cap applies to.
     * @param cap The agent's per-epoch allowance in that currency.
     * @param wouldSpend What the agent would have spent this epoch had the swap been allowed to stand.
     */
    error BudgetExceeded(uint8 currency, uint128 cap, uint256 wouldSpend);

    /// @notice Emitted on every swap that clears its budget check.
    event BudgetSpent(
        bytes32 indexed delegationHash, address indexed agent, uint128 spent0, uint128 spent1, uint64 epochStart
    );

    /// @notice Emitted when a principal revokes a delegation.
    event DelegationRevoked(bytes32 indexed delegationHash, address indexed principal);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) EIP712("HookForgeAgentBudget", "1") {}

    /// @notice The EIP-712 digest a principal signs to create `delegation`.
    function delegationDigest(Delegation calldata delegation) public view returns (bytes32) {
        return _hashTypedDataV4(hashDelegation(delegation));
    }

    /// @notice The struct hash identifying a delegation. Also the key every mapping here is stored under.
    function hashDelegation(Delegation calldata delegation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegation.principal,
                delegation.agent,
                PoolId.unwrap(delegation.poolId),
                delegation.cap0,
                delegation.cap1,
                delegation.epochLength,
                delegation.expiry,
                delegation.salt
            )
        );
    }

    /// @notice The EIP-712 digest an agent signs to authorise one swap.
    function swapDigest(SwapAuthorization calldata authorization) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SWAP_AUTHORIZATION_TYPEHASH, authorization.delegationHash, authorization.nonce, authorization.deadline
                )
            )
        );
    }

    /**
     * @notice Revoke a delegation, permanently.
     * @dev Callable only by the delegation's principal. There is deliberately no un-revoke: a principal who changes
     * their mind signs a fresh delegation with a different salt, which leaves the revoked one dead forever rather
     * than resurrecting an authorisation an agent may have leaked in the meantime.
     */
    function revoke(Delegation calldata delegation) external {
        if (msg.sender != delegation.principal) revert BadPrincipalSignature();
        bytes32 delegationHash = hashDelegation(delegation);
        revoked[delegationHash] = true;
        emit DelegationRevoked(delegationHash, msg.sender);
    }

    /// @notice What `delegation` may still spend this epoch, given everything recorded against it so far.
    function remainingBudget(Delegation calldata delegation)
        external
        view
        returns (uint256 remaining0, uint256 remaining1)
    {
        Usage memory usage = usageOf[hashDelegation(delegation)];
        // A stale epoch has already lapsed, so nothing recorded in it counts against the current one.
        if (_epochStart(delegation.epochLength) != usage.epochStart) return (delegation.cap0, delegation.cap1);
        remaining0 = delegation.cap0 > usage.spent0 ? delegation.cap0 - usage.spent0 : 0;
        remaining1 = delegation.cap1 > usage.spent1 ? delegation.cap1 - usage.spent1 : 0;
    }

    /// @dev The start of the epoch containing the current block, aligned to absolute time so every agent shares it.
    function _epochStart(uint32 epochLength) private view returns (uint64) {
        if (epochLength == 0) revert InvalidEpochLength();
        // Epoch boundaries are minutes or hours apart, so a proposer's seconds of drift cannot move one meaningfully.
        // The division precedes the multiplication on purpose: flooring to the epoch boundary is the whole point, and
        // casting to uint64 is safe because the result is at most `block.timestamp`.
        // forge-lint: disable-next-line(block-timestamp, divide-before-multiply, unsafe-typecast)
        return uint64((block.timestamp / epochLength) * epochLength);
    }

    /**
     * @dev Verifies the delegation and the swap authorisation, measures what the swap actually spent, and reverts if
     * that takes the agent past its cap. Reverting here unwinds the swap, so an over-budget trade never lands.
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (hookData.length == 0) revert AuthorizationRequired();

        (Delegation memory delegation, bytes memory principalSignature, SwapAuthorization memory authorization, bytes memory agentSignature)
        = abi.decode(hookData, (Delegation, bytes, SwapAuthorization, bytes));

        bytes32 delegationHash = _verify(key, delegation, principalSignature, authorization, agentSignature);
        _meter(delegationHash, delegation, delta);

        return (this.afterSwap.selector, 0);
    }

    /// @dev Checks both signatures, the pool, the expiries, the revocation and the nonce. Returns the delegation hash.
    function _verify(
        PoolKey calldata key,
        Delegation memory delegation,
        bytes memory principalSignature,
        SwapAuthorization memory authorization,
        bytes memory agentSignature
    ) private returns (bytes32 delegationHash) {
        if (PoolId.unwrap(delegation.poolId) != PoolId.unwrap(key.toId())) revert WrongPool();
        // Expiries are set in hours or days by the principal; seconds of proposer drift cannot reach them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > delegation.expiry || block.timestamp > authorization.deadline) revert Expired();

        delegationHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegation.principal,
                delegation.agent,
                PoolId.unwrap(delegation.poolId),
                delegation.cap0,
                delegation.cap1,
                delegation.epochLength,
                delegation.expiry,
                delegation.salt
            )
        );
        if (revoked[delegationHash]) revert Revoked();
        if (authorization.delegationHash != delegationHash) revert BadAgentSignature();

        // ERC-1271 as well as ECDSA, so either party may be a contract account.
        if (!SignatureChecker.isValidSignatureNow(delegation.principal, _hashTypedDataV4(delegationHash), principalSignature)) {
            revert BadPrincipalSignature();
        }

        bytes32 swapHash = _hashTypedDataV4(
            keccak256(
                abi.encode(SWAP_AUTHORIZATION_TYPEHASH, authorization.delegationHash, authorization.nonce, authorization.deadline)
            )
        );
        if (!SignatureChecker.isValidSignatureNow(delegation.agent, swapHash, agentSignature)) revert BadAgentSignature();

        if (nonceUsed[delegationHash][authorization.nonce]) revert NonceAlreadyUsed(authorization.nonce);
        nonceUsed[delegationHash][authorization.nonce] = true;
    }

    /// @dev Adds this swap's spend to the epoch in progress, resetting first if the epoch has rolled over.
    function _meter(bytes32 delegationHash, Delegation memory delegation, BalanceDelta delta) private {
        uint64 epochStart = _epochStart(delegation.epochLength);
        Usage memory usage = usageOf[delegationHash];
        if (usage.epochStart != epochStart) usage = Usage({epochStart: epochStart, spent0: 0, spent1: 0});

        // A negative delta is what the swapper paid. A positive one is what they received and is not a spend.
        uint256 spend0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 spend1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;

        uint256 total0 = uint256(usage.spent0) + spend0;
        uint256 total1 = uint256(usage.spent1) + spend1;
        if (total0 > delegation.cap0) revert BudgetExceeded(0, delegation.cap0, total0);
        if (total1 > delegation.cap1) revert BudgetExceeded(1, delegation.cap1, total1);

        // Casting to 'uint128' is safe because the lines above reverted unless each total is at or below its cap,
        // and both caps are uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        usage.spent0 = uint128(total0);
        // forge-lint: disable-next-line(unsafe-typecast)
        usage.spent1 = uint128(total1);
        usageOf[delegationHash] = usage;

        emit BudgetSpent(delegationHash, delegation.agent, usage.spent0, usage.spent1, epochStart);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "AgentBudget";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "agent-budget.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "agent";
        tags[1] = "delegation";
        tags[2] = "spending-limit";
        tags[3] = "eip712";
        tags[4] = "no-admin";
    }
}
