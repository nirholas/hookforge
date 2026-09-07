// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {UD60x18, ud} from "@prb/math/UD60x18.sol";

/**
 * @title WeightedMath
 * @notice The weighted geometric-mean invariant, `x^w * y^(1-w) = k`, and the swap maths that follows from it.
 *
 * @dev Shared by every curve in this catalogue whose pricing is a weighted product. A pool with a fixed weight uses
 * it directly; a pool whose weight moves on a schedule passes a different weight each time it is called, and nothing
 * else has to change, because the invariant is evaluated fresh on every quote rather than stored.
 *
 * All exponents are real numbers, so this needs a genuine `pow` rather than repeated squaring. Rounding is stated at
 * each function: an exact-input quote rounds the output down and an exact-output quote rounds the input up, both
 * against the trader, because a curve that rounds the other way is a curve that pays somebody to round-trip it.
 */
library WeightedMath {
    /// @dev The pool cannot fill the swap without emptying the side being bought.
    error InsufficientReserves();

    /// @notice The invariant `x^w0 * y^w1`, where the weights are in 18 decimals and sum to one.
    function invariant(uint256 reserve0, uint256 reserve1, UD60x18 weight0) internal pure returns (uint256) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
        UD60x18 weight1 = ud(1e18).sub(weight0);
        return ud(reserve0).pow(weight0).mul(ud(reserve1).pow(weight1)).unwrap();
    }

    /**
     * @notice The marginal price of currency0 in currency1, in 18 decimals.
     * @dev `(y / w1) / (x / w0)`. At equal weights and equal reserves this is one, as a constant-product pool is.
     */
    function spotPrice(uint256 reserve0, uint256 reserve1, UD60x18 weight0) internal pure returns (uint256) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
        UD60x18 weight1 = ud(1e18).sub(weight0);
        return ud(reserve1).div(weight1).div(ud(reserve0).div(weight0)).unwrap();
    }

    /**
     * @notice Output for a given input, rounded down.
     * @dev `out = reserveOut * (1 - (reserveIn / (reserveIn + in))^(wIn / wOut))`.
     */
    function amountOut(uint256 reserveIn, uint256 reserveOut, UD60x18 weightIn, UD60x18 weightOut, uint256 input)
        internal
        pure
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        UD60x18 ratio = ud(reserveIn).div(ud(reserveIn + input));
        UD60x18 factor = ratio.pow(weightIn.div(weightOut));
        return ud(reserveOut).mul(ud(1e18).sub(factor)).unwrap();
    }

    /**
     * @notice Input required for a given output, rounded up by one wei.
     * @dev `in = reserveIn * ((reserveOut / (reserveOut - out))^(wOut / wIn) - 1)`. Every operation in that
     * expression rounds down, and an exact-output quote that rounds down is one the pool cannot honour: it hands over
     * the full output having been paid slightly less than the curve requires.
     */
    function amountIn(uint256 reserveIn, uint256 reserveOut, UD60x18 weightIn, UD60x18 weightOut, uint256 output)
        internal
        pure
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        if (output >= reserveOut) revert InsufficientReserves();
        UD60x18 ratio = ud(reserveOut).div(ud(reserveOut - output));
        UD60x18 factor = ratio.pow(weightOut.div(weightIn));
        return ud(reserveIn).mul(factor.sub(ud(1e18))).unwrap() + 1;
    }
}
