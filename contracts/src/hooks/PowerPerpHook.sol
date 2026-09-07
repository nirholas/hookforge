// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {UD60x18, ud, convert} from "@prb/math/UD60x18.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";

/**
 * @title PowerPerpHook
 * @notice A pool with a weight, so a liquidity provider chooses how much of the move they want instead of always
 * getting the square root of it.
 *
 * @dev Providing to a constant-product pool is a position, and almost nobody picks it deliberately. Holding `x*y = k`
 * against a price move gives a payoff proportional to the square root of the price, always, with no way to ask for
 * more or less. A provider who is bullish and wants most of the upside, and a provider who wants to sit closer to
 * stable, are handed the identical exposure and told it is a fee opportunity.
 *
 * The generalisation has been known since Balancer: hold the weighted geometric mean constant,
 *
 *   x^w * y^(1-w) = k
 *
 * and the position's value moves with `price^(1-w)`. At `w = 0.5` that is the square root every constant-product pool
 * gives. At `w = 0.8` the pool holds mostly currency0 and the provider keeps most of its move. At `w = 0.2` the pool
 * is mostly currency1 and the provider is nearly flat to currency0. One parameter, and the provider's exposure is
 * something they chose.
 *
 * The swap maths follows from the invariant. Selling `dx` of currency0 into the pool leaves
 *
 *   dy = y * (1 - (x / (x + dx))^(w / (1 - w)))
 *
 * which is computed here in 60.18 fixed point. The exponent is a real number, not an integer, so this needs genuine
 * `pow`; it uses PRB Math rather than an approximation, because a curve that is subtly wrong in the tail is a curve
 * that pays somebody to find the tail.
 *
 * The reason this is worth having on v4 specifically: v4 pools are concentrated-liquidity pools, and concentration
 * and weighting are different tools. Concentration says where you are willing to quote. Weighting says what exposure
 * you want while you quote. Nothing in v4 offers the second, and a hook that replaces the curve is the only place it
 * can live.
 *
 * @custom:slug power-perp
 * @custom:family Curves
 * @custom:prior-art Weighted geometric-mean pools are Balancer's, and have been since 2020. The Squared and power-perpetual submissions for v4 build leveraged products on top of a pool rather than changing the pool's own curve. Bringing the weighted invariant to v4 as a custom curve, so a provider can pick their exposure to the pair they are quoting, is the contribution here; the maths is deliberately the well-understood one rather than something new.
 * @custom:limitation A weighted pool is more exposed to one side by construction, so a provider who picks a high weight and is wrong about direction loses more than a constant-product provider would. That is the point of the parameter, not a defect, but it does mean the weight is a directional view and should be chosen as one. Gas is also higher than a constant-product pool: every quote evaluates a real-exponent `pow`, which costs a few thousand gas more than a multiply.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract PowerPerpHook is ForgeCurveHook {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Weight on currency0, in basis points. `5000` is the ordinary constant-product pool.
    uint256 public immutable weight0Bps;

    /// @notice Swap fee in basis points, retained in the reserves for providers.
    uint256 public immutable swapFeeBps;

    /// @dev The weight must leave both sides a real share; a pool weighted entirely to one side is not a pool.
    error InvalidWeight();

    /// @dev The fee must be below 100%.
    error InvalidFee();

    /// @dev The pool cannot fill this swap without emptying the side being bought.
    error InsufficientReserves();

    /// @dev A quote was requested against an empty pool.
    error NoLiquidity();

    constructor(
        IPoolManager _poolManager,
        uint256 _weight0Bps,
        uint256 _swapFeeBps,
        string memory shareName,
        string memory shareSymbol
    ) ForgeCurveHook(_poolManager, shareName, shareSymbol) {
        // Bounded well inside (0, 1): weights near the extremes make the exponent enormous and the maths unstable
        // long before they make the pool useful.
        if (_weight0Bps < 1_000 || _weight0Bps > 9_000) revert InvalidWeight();
        if (_swapFeeBps >= BPS) revert InvalidFee();

        weight0Bps = _weight0Bps;
        swapFeeBps = _swapFeeBps;
    }

    /// @notice The invariant `x^w * y^(1-w)`, which every swap leaves unchanged before fees.
    function invariant() external view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;

        UD60x18 w = ud((weight0Bps * 1e18) / BPS);
        UD60x18 term0 = ud(reserve0).pow(w);
        UD60x18 term1 = ud(reserve1).pow(ud(1e18).sub(w));
        return term0.mul(term1).unwrap();
    }

    /// @notice The pool's marginal price of currency0 in currency1, in 18 decimals.
    function spotPrice() external view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;

        // Marginal price of a weighted pool: (y / (1 - w)) / (x / w).
        UD60x18 w = ud((weight0Bps * 1e18) / BPS);
        UD60x18 numerator = ud(reserve1).div(ud(1e18).sub(w));
        UD60x18 denominator = ud(reserve0).div(w);
        return numerator.div(denominator).unwrap();
    }

    /**
     * @notice What a swap actually pays or costs, net of the fee. This is the number the trader sees.
     * @param zeroForOne True to sell currency0 for currency1.
     * @param exactInput True when `specifiedAmount` is what the trader pays.
     * @param specifiedAmount The side the trader has fixed.
     */
    function quote(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 net,) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
        return net;
    }

    /// @notice The curve's answer before the fee.
    function quoteGross(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoLiquidity();

        // `wIn` weights the currency going in, `wOut` the one coming out.
        UD60x18 w0 = ud((weight0Bps * 1e18) / BPS);
        UD60x18 w1 = ud(1e18).sub(w0);
        (UD60x18 wIn, UD60x18 wOut) = zeroForOne ? (w0, w1) : (w1, w0);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        if (exactInput) {
            // out = reserveOut * (1 - (reserveIn / (reserveIn + in))^(wIn / wOut))
            UD60x18 ratio = ud(reserveIn).div(ud(reserveIn + specifiedAmount));
            UD60x18 factor = ratio.pow(wIn.div(wOut));
            return ud(reserveOut).mul(ud(1e18).sub(factor)).unwrap();
        }

        // in = reserveIn * ((reserveOut / (reserveOut - out))^(wOut / wIn) - 1)
        if (specifiedAmount >= reserveOut) revert InsufficientReserves();
        UD60x18 ratio = ud(reserveOut).div(ud(reserveOut - specifiedAmount));
        UD60x18 factor = ratio.pow(wOut.div(wIn));
        // Rounded up by one wei. Every operation in that expression rounds down, and an exact-output quote that
        // rounds down is a quote the pool cannot honour: it hands over the full output having been paid slightly
        // less than the curve requires. One wei per swap, always in the pool's favour, closes it.
        return ud(reserveIn).mul(factor.sub(ud(1e18))).unwrap() + 1;
    }

    /// @notice The fee a swap would pay, in the unspecified currency.
    function quoteFee(bool zeroForOne, bool exactInput, uint256 specifiedAmount) external view returns (uint256 fee) {
        (, fee) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
    }

    /// @dev The curve's answer with the fee applied in the direction the swap runs. See {StepCurveHook} for why here.
    function _quoteNet(bool zeroForOne, bool exactInput, uint256 specifiedAmount)
        private
        view
        returns (uint256 net, uint256 fee)
    {
        uint256 gross = quoteGross(zeroForOne, exactInput, specifiedAmount);
        // The fee rounds against the trader in both directions, for the same reason the quote does: a fee that
        // rounds down on an exact-output swap is a fee the providers did not receive.
        fee = exactInput ? (gross * swapFeeBps) / BPS : (gross * swapFeeBps + BPS - 1) / BPS;
        net = exactInput ? gross - fee : gross + fee;

        if (exactInput) {
            (uint256 reserve0, uint256 reserve1) = reserves();
            uint256 reserveOut = zeroForOne ? reserve1 : reserve0;
            if (net >= reserveOut) revert InsufficientReserves();
        }
    }

    /// @dev Quotes the swap on the weighted invariant, with the fee already applied in the settled amount.
    function _getUnspecifiedAmount(SwapParams calldata params) internal view override returns (uint256) {
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        (uint256 net,) = _quoteNet(params.zeroForOne, exactInput, specified);
        return net;
    }

    /// @dev Reports the fee {_getUnspecifiedAmount} already applied, recovered from the net figure for the event.
    function _getSwapFeeAmount(SwapParams calldata params, uint256 unspecifiedAmount)
        internal
        view
        override
        returns (uint256)
    {
        bool exactInput = params.amountSpecified < 0;
        uint256 gross = exactInput
            ? (unspecifiedAmount * BPS) / (BPS - swapFeeBps)
            : (unspecifiedAmount * BPS) / (BPS + swapFeeBps);
        return (gross * swapFeeBps) / BPS;
    }

    function hookName() external pure override returns (string memory) {
        return "PowerPerp";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "power-perp.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "custom-curve";
        tags[2] = "weighted";
        tags[3] = "lp-economics";
        tags[4] = "exposure";
    }
}
