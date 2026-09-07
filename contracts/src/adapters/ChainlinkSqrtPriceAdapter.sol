// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @dev The subset of Chainlink's aggregator interface this adapter uses.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title ChainlinkSqrtPriceAdapter
 * @notice Turns a Chainlink price feed into the `sqrtPriceX96` a Uniswap v4 pool speaks.
 *
 * @dev A Chainlink feed answers in its own decimals, for a pair in its own order, about tokens with their own
 * decimals. A pool's price is `sqrt(reserve1/reserve0) * 2**96` in raw token units. Getting between the two is three
 * decimal conversions and a square root, and every hook that needs an oracle would otherwise reimplement all four,
 * which is how off-by-a-decimal bugs get written.
 *
 * The conversion, in one line:
 *
 *   sqrtPriceX96 = sqrt( answer * 10**decimals1 * 2**192 / (10**feedDecimals * 10**decimals0) )
 *
 * `FullMath.mulDiv` carries the 512-bit intermediate, so the `2**192` factor never overflows on its way through, and
 * the square root of anything below `2**256` fits comfortably in the `uint160` a pool price is stored as.
 *
 * The adapter is immutable and holds nothing. It reverts rather than returning a wrong number: a non-positive answer
 * is not a low price, it is a broken feed, and a price that rounds to zero in pool units cannot be compared against
 * anything. Staleness is deliberately not enforced here; it is returned as `updatedAt` so each hook can apply the
 * tolerance its own pool needs.
 *
 * `invert` handles the common case where the feed quotes the pair the other way round from the pool.
 */
contract ChainlinkSqrtPriceAdapter is IPriceOracle {
    /// @notice The underlying Chainlink aggregator.
    IAggregatorV3 public immutable feed;

    /// @notice Decimals of the pool's `currency0`.
    uint8 public immutable decimals0;

    /// @notice Decimals of the pool's `currency1`.
    uint8 public immutable decimals1;

    /// @notice Decimals the feed answers in.
    uint8 public immutable feedDecimals;

    /// @notice True when the feed quotes currency0 per currency1 rather than currency1 per currency0.
    bool public immutable inverted;

    /// @dev The feed returned a non-positive answer, which means it is broken rather than cheap.
    error InvalidAnswer(int256 answer);

    /// @dev The converted price rounds to zero or does not fit a pool price. The pair is outside this feed's range.
    error PriceOutOfRange();

    constructor(IAggregatorV3 _feed, uint8 _decimals0, uint8 _decimals1, bool _inverted) {
        feed = _feed;
        decimals0 = _decimals0;
        decimals1 = _decimals1;
        feedDecimals = _feed.decimals();
        inverted = _inverted;
    }

    /// @inheritdoc IPriceOracle
    function sqrtPriceX96() external view returns (uint160 price, uint256 updatedAt) {
        (, int256 answer,, uint256 publishedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidAnswer(answer);

        // Numerator and denominator are assembled before dividing so that a feed whose decimals exceed the token's
        // never has to represent a fractional intermediate.
        // casting `answer` to 'uint256' is safe because the guard above rejects every non-positive answer.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 positiveAnswer = uint256(answer);

        uint256 numerator;
        uint256 denominator;
        if (inverted) {
            numerator = 10 ** feedDecimals * 10 ** decimals1;
            denominator = positiveAnswer * 10 ** decimals0;
        } else {
            numerator = positiveAnswer * 10 ** decimals1;
            denominator = 10 ** feedDecimals * 10 ** decimals0;
        }

        // ratioX192 = (token1 per token0) * 2**192, so its square root is the price scaled by 2**96.
        uint256 ratioX192 = FullMath.mulDiv(numerator, 1 << 192, denominator);
        uint256 root = FixedPointMathLib.sqrt(ratioX192);
        if (root == 0 || root > type(uint160).max) revert PriceOutOfRange();

        // casting to 'uint160' is safe because the guard above rejects any root above type(uint160).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(root), publishedAt);
    }
}
