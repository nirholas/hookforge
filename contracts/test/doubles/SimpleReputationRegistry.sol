// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IAgentReputation} from "src/interfaces/IAgentReputation.sol";

/**
 * @title SimpleReputationRegistry
 * @notice A self-attested reputation registry, used to exercise {ReputationFeeHook} against a real implementation.
 * @dev Deliberately trivial and deliberately not a production registry: anybody can set their own score. It exists
 * so the hook is tested against something that satisfies the interface honestly rather than against a mock that
 * pretends to. A real deployment points at ERC-8004 or an attestation aggregator.
 */
contract SimpleReputationRegistry is IAgentReputation {
    uint256 public constant SCALE = 10_000;

    mapping(address => uint256) private _scores;

    function set(address agent, uint256 score) external {
        _scores[agent] = score > SCALE ? SCALE : score;
    }

    /// @inheritdoc IAgentReputation
    function scoreOf(address agent) external view returns (uint256) {
        return _scores[agent];
    }

    /// @inheritdoc IAgentReputation
    function scoreScale() external pure returns (uint256) {
        return SCALE;
    }
}
