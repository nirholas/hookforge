// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IPriceOracle
 * @notice A reference price for a Uniswap v4 pool, expressed in the pool's own units.
 *
 * @dev Hooks that need an external price should not each learn a different oracle's interface, its decimals, its
 * staleness semantics and its failure modes. This interface is the seam: it returns the reference price already in
 * `sqrtPriceX96`, the exact form a pool's own price takes, so a hook can compare the two with no conversion and no
 * assumptions about where the number came from.
 *
 * `updatedAt` is the timestamp the underlying source last published. Freshness is the caller's policy, not the
 * adapter's, because how stale is too stale depends on the pool rather than on the feed.
 */
interface IPriceOracle {
    /// @notice The reference price as `sqrt(token1/token0) * 2**96`, and when the underlying source last published it.
    function sqrtPriceX96() external view returns (uint160 price, uint256 updatedAt);
}
