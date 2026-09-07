// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {UD60x18, ud} from "@prb/math/UD60x18.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";
import {WeightedMath} from "../libraries/WeightedMath.sol";

/**
 * @title EpochRebalanceHook
 * @notice An index whose whole future is fixed before anybody deposits: the pool's target allocation glides along a
 * schedule written at deployment, and nobody, including the deployer, can change it afterwards.
 *
 * @dev A weighted pool is already an index fund. Holding `x^w * y^(1-w)` constant keeps the value split at `w` to
 * `1-w` without anybody trading, because arbitrageurs restore the ratio for free every time the price moves. That
 * result is Balancer's and it is why weighted pools are described as self-rebalancing.
 *
 * What a real index also needs is reconstitution: the target itself changes. Balancer does this with an owner call
 * that starts a gradual weight update, and that is the part worth improving on, for two reasons.
 *
 * The first is trust. A provider deposits into a 60/40 pool and the owner can make it 20/80 next week. Whatever the
 * governance around that key, the provider's exposure is not theirs to control, and the pool's terms are a promise
 * rather than a property.
 *
 * The second is the rebalance itself. A weight change is a trade the pool must do, and if it happens as one step the
 * whole trade is available at one price in one block, which is the most arbitrageable shape a rebalance can have.
 * Every index that reconstitutes on a known date pays for this, and it has a name: index front-running.
 *
 * This hook fixes both by fixing the schedule. Weight checkpoints are set at construction and interpolated linearly
 * between, so the pool's allocation on any future date is computable by anyone from the moment it exists. A provider
 * knows what they are joining for the whole life of the pool. And because the weight moves continuously rather than
 * in a step, the rebalancing flow is spread across the glide instead of concentrated into one block: there is no
 * single moment worth racing to, because at every moment only an instant's worth of the trade is available.
 *
 * The same mechanism is a liquidity bootstrapping pool when the schedule is two points and the first weight is
 * lopsided, so this covers that case without a separate contract.
 *
 * @custom:slug epoch-rebalance
 * @custom:family Time
 * @custom:prior-art Weighted pools as self-rebalancing indices are Balancer's, as are gradual weight updates, which are triggered by an owner. Liquidity bootstrapping pools are the two-point case. Making the entire weight schedule immutable and set before the first deposit, so the pool's future allocation is a property a provider can verify rather than a promise a key holder can revise, is the contribution here, along with the observation that a continuous glide removes the single arbitrageable print a stepped reconstitution creates.
 * @custom:limitation The schedule cannot respond to anything. An index that needs to react to a delisting, a merger or a depeg cannot be expressed here, and pretending otherwise by picking a schedule that happens to look right is worse than using a pool with a keeper. The glide also does not eliminate rebalancing cost, it spreads it: the pool still trades into the new weight and still pays for that, it simply does not hand the whole trade to one participant in one block.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract EpochRebalanceHook is ForgeCurveHook {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice The most checkpoints a schedule may hold. A glide is a handful of points, not a time series.
    uint256 public constant MAX_CHECKPOINTS = 8;

    /// @notice A point on the weight schedule.
    struct Checkpoint {
        /// @notice When this weight is reached.
        uint64 time;
        /// @notice Target weight on currency0 at that time, in basis points.
        uint16 weight0Bps;
    }

    /// @notice The immutable schedule, in ascending time order.
    Checkpoint[] private _schedule;

    /// @notice Swap fee in basis points, retained in the reserves for providers.
    uint256 public immutable swapFeeBps;

    /// @dev The schedule was empty, too long, out of order, or carried a weight outside the usable band.
    error InvalidSchedule();

    /// @dev The fee must be below 100%.
    error InvalidFee();

    /// @dev A quote was requested against an empty pool.
    error NoLiquidity();

    /// @dev The pool cannot fill this swap without emptying the side being bought.
    error InsufficientReserves();

    constructor(
        IPoolManager _poolManager,
        Checkpoint[] memory schedule_,
        uint256 _swapFeeBps,
        string memory shareName,
        string memory shareSymbol
    ) ForgeCurveHook(_poolManager, shareName, shareSymbol) {
        if (schedule_.length == 0 || schedule_.length > MAX_CHECKPOINTS) revert InvalidSchedule();
        if (_swapFeeBps >= BPS) revert InvalidFee();

        for (uint256 i = 0; i < schedule_.length; i++) {
            // Weights are bounded well inside (0, 1): near the extremes the exponent is enormous and the curve stops
            // behaving like a market long before the weight becomes useful.
            if (schedule_[i].weight0Bps < 1_000 || schedule_[i].weight0Bps > 9_000) revert InvalidSchedule();
            if (i > 0 && schedule_[i].time <= schedule_[i - 1].time) revert InvalidSchedule();
            _schedule.push(schedule_[i]);
        }
        swapFeeBps = _swapFeeBps;
    }

    /// @notice The whole schedule, so anybody can compute the pool's allocation on any future date.
    function schedule() external view returns (Checkpoint[] memory) {
        return _schedule;
    }

    /// @notice How many checkpoints the schedule holds.
    function checkpointCount() external view returns (uint256) {
        return _schedule.length;
    }

    /**
     * @notice The target weight on currency0 at `timestamp`, in basis points.
     * @dev Flat before the first checkpoint and after the last, linear between. A pool asked about a date beyond its
     * schedule holds its final allocation, which is the honest answer: the schedule said nothing about later.
     */
    function weightAtBps(uint256 timestamp) public view returns (uint256) {
        uint256 length = _schedule.length;
        if (timestamp <= _schedule[0].time) return _schedule[0].weight0Bps;
        if (timestamp >= _schedule[length - 1].time) return _schedule[length - 1].weight0Bps;

        for (uint256 i = 1; i < length; i++) {
            Checkpoint memory next = _schedule[i];
            if (timestamp > next.time) continue;

            Checkpoint memory previous = _schedule[i - 1];
            uint256 span = uint256(next.time) - previous.time;
            uint256 elapsed = timestamp - previous.time;

            // Interpolated in whichever direction the glide runs, so a schedule may raise or lower the weight.
            if (next.weight0Bps >= previous.weight0Bps) {
                return previous.weight0Bps + ((uint256(next.weight0Bps) - previous.weight0Bps) * elapsed) / span;
            }
            return previous.weight0Bps - ((uint256(previous.weight0Bps) - next.weight0Bps) * elapsed) / span;
        }
        return _schedule[length - 1].weight0Bps;
    }

    /// @notice The target weight right now, in basis points.
    function currentWeightBps() external view returns (uint256) {
        return weightAtBps(block.timestamp);
    }

    /// @notice The invariant the pool holds constant at the current weight.
    function invariant() external view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        return WeightedMath.invariant(reserve0, reserve1, _weight0());
    }

    /// @notice The pool's marginal price of currency0 in currency1, in 18 decimals.
    function spotPrice() external view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        return WeightedMath.spotPrice(reserve0, reserve1, _weight0());
    }

    /// @notice What a swap actually pays or costs, net of the fee. This is the number the trader sees.
    function quote(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 net,) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
        return net;
    }

    /// @notice The curve's answer before the fee, at the weight in force right now.
    function quoteGross(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoLiquidity();

        UD60x18 w0 = _weight0();
        UD60x18 w1 = ud(1e18).sub(w0);
        (UD60x18 wIn, UD60x18 wOut) = zeroForOne ? (w0, w1) : (w1, w0);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        return exactInput
            ? WeightedMath.amountOut(reserveIn, reserveOut, wIn, wOut, specifiedAmount)
            : WeightedMath.amountIn(reserveIn, reserveOut, wIn, wOut, specifiedAmount);
    }

    /// @notice The fee a swap would pay, in the unspecified currency.
    function quoteFee(bool zeroForOne, bool exactInput, uint256 specifiedAmount) external view returns (uint256 fee) {
        (, fee) = _quoteNet(zeroForOne, exactInput, specifiedAmount);
    }

    /// @dev The weight in force right now, in 18 decimals.
    function _weight0() private view returns (UD60x18) {
        // The glide is measured in days or weeks; the seconds a proposer can shift cannot move it meaningfully.
        // forge-lint: disable-next-line(block-timestamp)
        return ud((weightAtBps(block.timestamp) * 1e18) / BPS);
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

    /// @dev Quotes the swap at the scheduled weight, with the fee already applied in the settled amount.
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
        return "EpochRebalance";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "epoch-rebalance.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "index";
        tags[2] = "rebalancing";
        tags[3] = "schedule";
        tags[4] = "no-admin";
    }
}
