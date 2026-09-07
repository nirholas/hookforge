// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IAggregatorV3} from "src/adapters/ChainlinkSqrtPriceAdapter.sol";

/**
 * @notice A Chainlink aggregator standing in for a live feed inside tests.
 * @dev Test-only. It exists so a test can put the feed in states a real one reaches rarely and at inconvenient times:
 * stale, negative, or moved by an exact amount. It is never deployed and never imported by `src`.
 */
contract TestAggregator is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
