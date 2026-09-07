// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";

/**
 * @title StepCurveHook
 * @notice A pool whose price moves in discrete steps instead of continuously, so there is no infinitesimal arbitrage
 * to take and a quote holds still long enough to be worth quoting.
 *
 * @dev A constant-product pool changes its price on every swap, by any amount, however small. That is elegant and it
 * has a cost that falls entirely on the people providing the liquidity: the price is always slightly wrong by an
 * amount somebody can capture, and the smaller the increment the more often it is worth capturing. Continuous pricing
 * is what makes an AMM permanently arbitrageable rather than occasionally.
 *
 * Every other market prices in ticks. Equities trade in cents, bonds in thirty-seconds, futures in whatever the
 * exchange decided, and the reason is not tradition: a minimum increment means a quote is worth something for a
 * while, because moving the price at all costs a whole increment rather than a rounding error.
 *
 * This pool prices in increments. The quote is constant across a band of inventory `stepSize` wide and falls by
 * `stepX96` when the band is crossed, so:
 *
 *   price(reserve0) = max(minPriceX96, startPriceX96 - (reserve0 / stepSize) * stepX96)
 *
 * Within a band the pool is a constant-sum market maker at a fixed price, which is to say it fills at exactly the
 * quote with no slippage at all. A swap that would cross bands walks them, filling each at its own price. So a small
 * trade sees a firm quote and no slippage, and a large trade sees exactly the depth the ladder was configured with.
 *
 * The consequence for arbitrage is the point. An external price move smaller than one increment is not tradeable
 * against this pool at all, because moving the price requires consuming a whole band. Providers are exposed to moves
 * larger than the increment and immune to noise below it, which is the trade every quoting venue in the world makes.
 *
 * Liquidity is fungible and proportional; see {ForgeCurveHook}. There are no ticks and no ranges, because the ladder
 * is the range.
 *
 * @custom:slug step-curve
 * @custom:family Curves
 * @custom:prior-art Constant-sum hooks (Uniswap's own constant-sum example, the StableSwap and Orbital submissions) replace the curve with a different continuous one. Bancor's Carbon quotes discrete asymmetric ladders, off v4. Discrete tick pricing is universal outside crypto. A v4 custom curve that is constant-sum inside a band and steps between bands, so a quote is firm below the increment and depth is exactly what was configured, is the contribution here.
 * @custom:limitation A swap that crosses many bands walks them one at a time, so gas grows with the number of bands crossed and a swap larger than `MAX_STEPS` bands reverts rather than filling partially. Size `stepSize` against the trades the pool expects. The ladder is also fixed at deployment: a pool whose asset moves far outside the configured range runs out of ladder and stops quoting on that side, which is honest but is not the same as a curve that quotes everywhere.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract StepCurveHook is ForgeCurveHook {
    /// @notice Fixed point one, in the Q96 format prices are quoted in.
    uint256 internal constant Q96 = 1 << 96;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /**
     * @notice The most bands one swap may cross.
     * @dev A bound rather than a preference: without it a large enough swap is an unbounded loop, which on a chain is
     * a denial of service against the whole block rather than a slow transaction.
     */
    uint256 public constant MAX_STEPS = 256;

    /// @notice Price of one unit of currency0, in currency1, at the top of the ladder. Q96.
    uint256 public immutable startPriceX96;

    /// @notice How much the price falls per band. Q96.
    uint256 public immutable stepX96;

    /// @notice The price the ladder bottoms out at. Q96.
    uint256 public immutable minPriceX96;

    /// @notice Width of one band, in units of currency0.
    uint256 public immutable stepSize;

    /// @notice Swap fee in basis points, taken in the unspecified currency and left in the reserves for providers.
    uint256 public immutable swapFeeBps;

    /// @dev The swap would cross more than `MAX_STEPS` bands. Split it, or the pool needs a wider `stepSize`.
    error SwapTooLarge();

    /// @dev The ladder cannot fill this swap: the pool has run out of the currency being bought.
    error InsufficientReserves();

    /// @dev A constructor argument was zero or inconsistent.
    error InvalidLadder();

    constructor(
        IPoolManager _poolManager,
        uint256 _startPriceX96,
        uint256 _stepX96,
        uint256 _minPriceX96,
        uint256 _stepSize,
        uint256 _swapFeeBps,
        string memory shareName,
        string memory shareSymbol
    ) ForgeCurveHook(_poolManager, shareName, shareSymbol) {
        if (_stepSize == 0 || _startPriceX96 == 0 || _minPriceX96 == 0) revert InvalidLadder();
        if (_minPriceX96 > _startPriceX96) revert InvalidLadder();
        if (_swapFeeBps >= BPS) revert InvalidLadder();

        startPriceX96 = _startPriceX96;
        stepX96 = _stepX96;
        minPriceX96 = _minPriceX96;
        stepSize = _stepSize;
        swapFeeBps = _swapFeeBps;
    }

    /// @notice The price the pool quotes when it holds `reserve0` of currency0. Q96, currency1 per currency0.
    function priceAt(uint256 reserve0) public view returns (uint256) {
        // The division precedes the multiplication deliberately: flooring the reserve to a whole band index is the
        // entire mechanism, and "fixing" the order would make the price continuous again.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 fall = (reserve0 / stepSize) * stepX96;
        if (fall >= startPriceX96 - minPriceX96) return minPriceX96;
        return startPriceX96 - fall;
    }

    /// @notice The price the pool is quoting right now.
    function currentPriceX96() external view returns (uint256) {
        return priceAt(reserve(poolKey().currency0));
    }

    /**
     * @notice What a swap actually pays or costs, walking the ladder exactly as a real swap would and applying the fee.
     * @param zeroForOne True to sell currency0 for currency1.
     * @param exactInput True when `specifiedAmount` is what the trader pays, false when it is what they receive.
     * @param specifiedAmount The side the trader has fixed.
     * @return unspecifiedAmount The other side, net of the swap fee. This is the number the trader sees.
     */
    function quote(bool zeroForOne, bool exactInput, uint256 specifiedAmount)
        public
        view
        returns (uint256 unspecifiedAmount)
    {
        (unspecifiedAmount,) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
    }

    /// @notice The ladder's answer before the fee, which is the price the pool's own curve quoted.
    function quoteGross(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        return zeroForOne
            ? _quoteSell(reserve0, reserve1, exactInput, specifiedAmount)
            : _quoteBuy(reserve0, reserve1, exactInput, specifiedAmount);
    }

    /**
     * @notice The fee a swap would pay, in the unspecified currency.
     * @dev Reported separately because it is not visible in the trader's own numbers: the fee never leaves the
     * reserves, it simply is not handed over, and providers see it as reserves that grew.
     */
    function quoteFee(bool zeroForOne, bool exactInput, uint256 specifiedAmount) external view returns (uint256 fee) {
        (, fee) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
    }

    /**
     * @dev The ladder's answer with the fee applied in the direction the swap runs.
     *
     * On an exact-input swap the trader receives less than the curve quoted. On an exact-output swap they pay more.
     * Either way the difference stays in the reserves, which is what pays the providers: a share is a claim on the
     * reserves, so a reserve that kept the fee is a share worth more.
     */
    function _quoteNet(bool zeroForOne, bool exactInput, uint256 specifiedAmount)
        private
        view
        returns (uint256 net, uint256 fee)
    {
        uint256 gross = quoteGross(zeroForOne, exactInput, specifiedAmount);
        fee = (gross * swapFeeBps) / BPS;
        net = exactInput ? gross - fee : gross + fee;
    }

    /// @dev Selling currency0 into the pool. Reserve0 rises, so the ladder walks downward in price.
    function _quoteSell(uint256 reserve0, uint256 reserve1, bool exactInput, uint256 specified)
        private
        view
        returns (uint256)
    {
        uint256 r0 = reserve0;
        uint256 remaining = specified;
        uint256 accumulated;

        for (uint256 i = 0; i < MAX_STEPS; i++) {
            if (remaining == 0) return accumulated;

            uint256 price = priceAt(r0);
            // Currency0 that fits before the next band boundary.
            uint256 room = stepSize - (r0 % stepSize);

            if (exactInput) {
                uint256 take = remaining < room ? remaining : room;
                uint256 out = (take * price) / Q96;
                if (out > reserve1 - accumulated) revert InsufficientReserves();
                accumulated += out;
                r0 += take;
                remaining -= take;
            } else {
                // `remaining` is currency1 still owed to the trader; convert this band's room into currency1.
                uint256 bandOut = (room * price) / Q96;
                if (remaining <= bandOut) {
                    // Round the input up, so rounding never favours the trader over the pool.
                    accumulated += (remaining * Q96 + price - 1) / price;
                    return accumulated;
                }
                accumulated += room;
                r0 += room;
                remaining -= bandOut;
            }
        }
        revert SwapTooLarge();
    }

    /// @dev Buying currency0 out of the pool. Reserve0 falls, so the ladder walks upward in price.
    function _quoteBuy(uint256 reserve0, uint256 reserve1, bool exactInput, uint256 specified)
        private
        view
        returns (uint256)
    {
        uint256 r0 = reserve0;
        uint256 remaining = specified;
        uint256 accumulated;

        for (uint256 i = 0; i < MAX_STEPS; i++) {
            if (remaining == 0) return accumulated;
            if (r0 == 0) revert InsufficientReserves();

            // Room below the current boundary. Sitting exactly on one means the whole band below is available.
            uint256 position = r0 % stepSize;
            uint256 room = position == 0 ? stepSize : position;
            if (room > r0) room = r0;

            // The band being consumed is the one just below the current reserve, which is where its price is read.
            uint256 price = priceAt(r0 - 1);
            if (price == 0) revert InvalidLadder();

            if (exactInput) {
                // `remaining` is currency1 the trader is paying.
                uint256 bandCost = (room * price) / Q96;
                if (remaining < bandCost) {
                    accumulated += (remaining * Q96) / price;
                    return accumulated;
                }
                accumulated += room;
                r0 -= room;
                remaining -= bandCost;
            } else {
                // `remaining` is currency0 the trader wants out.
                uint256 take = remaining < room ? remaining : room;
                // Round the input up, for the same reason as above.
                accumulated += (take * price + Q96 - 1) / Q96;
                r0 -= take;
                remaining -= take;
            }
        }
        revert SwapTooLarge();
    }

    /**
     * @dev Quotes the swap by walking the ladder, with the fee already applied.
     *
     * The fee has to be applied here rather than left to `_getSwapFeeAmount`, because the base contract settles the
     * amount this function returns and uses `_getSwapFeeAmount` only to report the fee in its event. A hook that
     * returned a gross amount here and a fee there would emit a fee it never actually charged.
     */
    function _getUnspecifiedAmount(SwapParams calldata params) internal view override returns (uint256) {
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        (uint256 net,) = _quoteNet(params.zeroForOne, exactInput, specified);
        return net;
    }

    /**
     * @dev Reports the fee that {_getUnspecifiedAmount} already applied, for the base contract's event.
     *
     * `unspecifiedAmount` arrives net, so the gross is recovered before taking the fee off it. Reporting a fee
     * computed from the net figure would understate it on an exact-input swap and overstate it on an exact-output
     * one, and the event is the only record anybody indexing this pool will have.
     */
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
        return "StepCurve";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "step-curve.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "custom-curve";
        tags[2] = "discrete-pricing";
        tags[3] = "mev";
        tags[4] = "oracle-free";
    }
}
