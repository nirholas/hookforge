// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IFlowStats
 * @notice Published statistics about the order flow a pool receives.
 *
 * @dev Almost every fee mechanism in this catalogue is a guess about who is trading: the staleness tax guesses from
 * elapsed time, the priority-fee tax guesses from what the trade bid for its place in the block. Nothing publishes
 * the answer, so every hook re-derives it privately and no two agree.
 *
 * This is the seam for publishing it. A contract implementing this interface measures a pool's flow and exposes the
 * measurement to anyone: other hooks, routers deciding where to send an order, liquidity providers deciding whether a
 * pool is worth quoting, and indexers ranking pools by something more meaningful than volume.
 */
interface IFlowStats {
    /**
     * @notice Raw counters for a pool.
     * @param swaps Every swap the pool has seen.
     * @param leadSwaps Swaps that were the first in their block.
     * @param leadTicks Cumulative absolute tick movement caused by first-in-block swaps.
     * @param followTicks Cumulative absolute tick movement caused by every other swap.
     */
    function flowStats(PoolId id)
        external
        view
        returns (uint256 swaps, uint256 leadSwaps, uint256 leadTicks, uint256 followTicks);

    /// @notice The share of swaps that were first in their block, in basis points. Zero when nothing has traded.
    function leadShareBps(PoolId id) external view returns (uint256);

    /**
     * @notice How much more the average first-in-block swap moves the price than the average later one, in basis
     * points of a ratio. `10_000` means they move it equally; `30_000` means three times as far.
     */
    function leadImpactRatioBps(PoolId id) external view returns (uint256);
}
