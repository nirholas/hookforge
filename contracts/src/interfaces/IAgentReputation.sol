// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title IAgentReputation
 * @notice The minimum a pool needs from a reputation registry to price a counterparty.
 *
 * @dev Deliberately one function. Reputation systems disagree about almost everything (what is scored, over what
 * window, weighted by whom) and a pool has no business having an opinion on any of it. What a pool needs is a number
 * and a range, so it can turn "this counterparty has behaved well" into "this counterparty pays less", and leave the
 * hard part to whoever is qualified to judge it.
 *
 * Implementations include the ERC-8004 identity and reputation registries, attestation aggregators, and any purely
 * local scheme a venue wants to run for itself. A hook consuming this is trusting the registry completely, which is
 * why the registry is chosen once, at deployment, and cannot be changed afterwards.
 */
interface IAgentReputation {
    /**
     * @notice The score for `agent`, where zero is unknown or worst and `SCORE_SCALE` is best.
     * @dev Must not revert for an unknown agent: return zero. A registry that reverts on a stranger would make every
     * pool consuming it unusable by strangers, which is the opposite of what a reputation system is for.
     */
    function scoreOf(address agent) external view returns (uint256);

    /// @notice The value {scoreOf} returns for a perfect score, so a consumer can normalise without guessing.
    function scoreScale() external view returns (uint256);
}
