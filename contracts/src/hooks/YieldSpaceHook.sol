// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {UD60x18, ud} from "@prb/math/UD60x18.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";

/**
 * @title YieldSpaceHook
 * @notice An interest-rate market as a Uniswap v4 pool: the curve quotes a yield rather than a price, and converges
 * to par at maturity on its own.
 *
 * @dev A zero-coupon claim is worth less than the thing it pays out, by exactly the interest between now and
 * maturity, and that discount shrinks to nothing as maturity arrives. Quote it on a constant-product curve and the
 * curve does not know that. It prices the claim as a permanently distinct asset, so the pool's own convergence to par
 * is something arbitrageurs have to impose on it, trade by trade, and the liquidity provider pays for every one of
 * those trades.
 *
 * YieldSpace, from the Yield protocol's 2019 paper, is the curve that knows. It holds
 *
 *   x^(1 - t) + y^(1 - t) = k
 *
 * where `t` is the time to maturity as a fraction of a year. Far from maturity `t` is large, the exponent is small,
 * and the curve is steep: a big discount, and the pool quotes a rate. As maturity approaches `t` goes to zero, the
 * exponent goes to one, and the invariant becomes `x + y = k`, a constant-sum pool that trades one for one. The
 * convergence is the curve, not an arbitrage opportunity, so nobody has to be paid to enforce it.
 *
 * The consequence for the provider is the whole point. On a constant-product pool, holding a maturing claim means
 * being run over as it converges. Here the pool moves with it, so what the provider earns is fees on rate trading
 * rather than a slow bleed to whoever noticed the calendar.
 *
 * `currency0` is the underlying and `currency1` is the claim on it. The pool's implied rate is published by
 * {impliedRate}, in ray per year, which is the number this market is actually about.
 *
 * @custom:slug yield-space
 * @custom:family Curves
 * @custom:prior-art The curve is the Yield protocol's YieldSpace (Niemerg, Robinson, Livnev, 2019), and Notional and Pendle ship relatives of it. All of them are their own AMMs. Bringing it to v4 as a custom curve, so a fixed-rate market is an ordinary pool that every v4 router, indexer and position manager already understands, is the contribution here; the maths is deliberately theirs.
 * @custom:limitation The time term is clamped at one year, so a claim maturing further out than that is priced as if it matured in a year and the pool will quote it wrong until it comes inside the window. The pool also has no idea whether the claim is honoured: it converges to par because the clock says so, and if the issuer defaults the curve keeps confidently quoting par on a worthless asset. That risk belongs to whoever chose the pair.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract YieldSpaceHook is ForgeCurveHook {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Seconds in the year the rate is quoted against.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice When the claim matures and the curve becomes constant-sum.
    uint256 public immutable maturity;

    /// @notice Swap fee in basis points, retained in the reserves for providers.
    uint256 public immutable swapFeeBps;

    /// @dev The maturity must be in the future when the pool is created.
    error MaturityInThePast();

    /// @dev The fee must be below 100%.
    error InvalidFee();

    /// @dev The curve cannot fill this swap without emptying the side being bought.
    error InsufficientReserves();

    /// @dev A quote was requested against an empty pool.
    error NoLiquidity();

    constructor(
        IPoolManager _poolManager,
        uint256 _maturity,
        uint256 _swapFeeBps,
        string memory shareName,
        string memory shareSymbol
    ) ForgeCurveHook(_poolManager, shareName, shareSymbol) {
        // A maturity is set weeks or months out; the seconds a proposer can shift cannot reach it.
        // forge-lint: disable-next-line(block-timestamp)
        if (_maturity <= block.timestamp) revert MaturityInThePast();
        if (_swapFeeBps >= BPS) revert InvalidFee();

        maturity = _maturity;
        swapFeeBps = _swapFeeBps;
    }

    /// @notice Seconds until maturity, or zero once it has passed.
    function timeToMaturity() public view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp >= maturity ? 0 : maturity - block.timestamp;
    }

    /**
     * @notice The curve's exponent right now, in 18 decimals. One at maturity, smaller the further out it is.
     * @dev Clamped at one year: beyond that the exponent would go to zero and the curve would stop being a market.
     * A pool for a longer-dated claim simply prices it as one-year paper until it comes inside the window, which is
     * wrong but bounded, and is stated as a limitation rather than hidden.
     */
    function exponent() public view returns (UD60x18) {
        uint256 remaining = timeToMaturity();
        if (remaining >= SECONDS_PER_YEAR) return ud(1); // effectively zero, the steepest the curve gets
        UD60x18 t = ud((remaining * 1e18) / SECONDS_PER_YEAR);
        return ud(1e18).sub(t);
    }

    /// @notice The invariant `x^a + y^a`, which every swap leaves unchanged before fees.
    function invariant() public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        UD60x18 a = exponent();
        return ud(reserve0).pow(a).add(ud(reserve1).pow(a)).unwrap();
    }

    /**
     * @notice The annualised rate the pool is currently quoting, in 18 decimals (`0.05e18` is 5%).
     * @dev Derived from the marginal price of the claim in the underlying: a claim trading at 0.95 with three months
     * to run is quoting roughly 21% annualised. Returns zero at or after maturity, where there is no rate left.
     */
    function impliedRate() external view returns (uint256) {
        uint256 remaining = timeToMaturity();
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (remaining == 0 || reserve0 == 0 || reserve1 == 0) return 0;

        // Marginal price of currency1 in currency0 on this curve: (y / x)^(a - 1), which is (x / y)^(1 - a).
        UD60x18 a = exponent();
        UD60x18 price = ud(reserve0).div(ud(reserve1)).pow(ud(1e18).sub(a));
        if (price.unwrap() >= 1e18) return 0; // trading at or above par: no positive yield to report

        // rate = (1 / price - 1) * yearFraction, the simple annualisation this market quotes in.
        UD60x18 discount = ud(1e18).div(price).sub(ud(1e18));
        return discount.mul(ud((SECONDS_PER_YEAR * 1e18) / remaining)).unwrap();
    }

    /// @notice What a swap actually pays or costs, net of the fee. This is the number the trader sees.
    function quote(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 net,) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
        return net;
    }

    /// @notice The curve's answer before the fee.
    function quoteGross(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoLiquidity();

        UD60x18 a = exponent();
        UD60x18 k = ud(reserve0).pow(a).add(ud(reserve1).pow(a));
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        if (exactInput) {
            // The side coming out after the trade: (k - (in + dx)^a)^(1/a).
            UD60x18 consumed = ud(reserveIn + specifiedAmount).pow(a);
            if (consumed.unwrap() >= k.unwrap()) revert InsufficientReserves();
            uint256 remainingOut = k.sub(consumed).pow(ud(1e18).div(a)).unwrap();
            if (remainingOut >= reserveOut) return 0;
            return reserveOut - remainingOut;
        }

        // The side going in after the trade: (k - (out - dy)^a)^(1/a).
        if (specifiedAmount >= reserveOut) revert InsufficientReserves();
        UD60x18 left = ud(reserveOut - specifiedAmount).pow(a);
        if (left.unwrap() >= k.unwrap()) revert InsufficientReserves();
        uint256 requiredIn = k.sub(left).pow(ud(1e18).div(a)).unwrap();
        if (requiredIn <= reserveIn) revert InsufficientReserves();
        // Rounded up by one wei: every operation above rounds down, and an exact-output quote that rounds down is
        // one the pool cannot honour.
        return (requiredIn - reserveIn) + 1;
    }

    /// @notice The fee a swap would pay, in the unspecified currency.
    function quoteFee(bool zeroForOne, bool exactInput, uint256 specifiedAmount) external view returns (uint256 fee) {
        (, fee) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
    }

    /// @dev The curve's answer with the fee applied in the direction the swap runs.
    function _quoteNet(bool zeroForOne, bool exactInput, uint256 specifiedAmount)
        private
        view
        returns (uint256 net, uint256 fee)
    {
        uint256 gross = quoteGross(zeroForOne, exactInput, specifiedAmount);
        fee = exactInput ? (gross * swapFeeBps) / BPS : (gross * swapFeeBps + BPS - 1) / BPS;
        net = exactInput ? gross - fee : gross + fee;

        if (exactInput) {
            (uint256 reserve0, uint256 reserve1) = reserves();
            uint256 reserveOut = zeroForOne ? reserve1 : reserve0;
            if (net >= reserveOut) revert InsufficientReserves();
        }
    }

    /// @dev Quotes the swap on the YieldSpace invariant, with the fee already applied in the settled amount.
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
        return "YieldSpace";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "yield-space.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "custom-curve";
        tags[2] = "fixed-rate";
        tags[3] = "maturity";
        tags[4] = "rates";
    }
}
