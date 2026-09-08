// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SD59x18, sd} from "@prb/math/SD59x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";

/**
 * @title LMSRHook
 * @notice A pool whose worst case a provider can read before they deposit.
 *
 * @dev A constant-product provider's exposure has no upper bound. As the price moves, the position converges on
 * holding only the losing side, and the loss against simply having held the two tokens grows without limit. Everyone
 * knows this and nobody can quote it, because the answer depends on where the price goes and the curve quotes at
 * every price there is.
 *
 * Robin Hanson's logarithmic market scoring rule was built for exactly this problem, in prediction markets, in 2003:
 * a market maker that will always quote, and whose total loss is bounded by a constant chosen when the market opens.
 * The bound is the whole reason it is used. It has never been the curve of a general-purpose AMM because a
 * bounded-loss maker must also be a bounded-*range* maker, and a pool that stops quoting past a price is a worse
 * product right up until the day it is the only pool that did not get emptied.
 *
 * This pool holds the invariant
 *
 *   exp(-reserve0 / b) + exp(-reserve1 / b) = k
 *
 * which prices token0 in token1 at exp((reserve1 - reserve0) / b): exactly one at balance, falling smoothly as the
 * pool fills with token0. The parameter `b` is depth and it is also the bound. Larger `b` is flatter near parity and
 * a wider quoting range; smaller `b` is a tighter market that gives up sooner. There is one number to choose and it
 * means one thing.
 *
 * What a provider gets that no constant-product pool offers is a figure: {maxLoss} is what this curve can cost them
 * in the worst case anybody can construct, published on-chain, before they deposit. Beyond the range the curve
 * refuses the trade instead of quoting a price it cannot honour, which is the same promise stated from the other end.
 *
 * @custom:slug lmsr
 * @custom:family Curves
 * @custom:prior-art The scoring rule is Hanson's, and Gnosis, Augur and Polymarket's predecessors all ran variants of it for prediction markets, where outcomes sum to one and shares are minted rather than held. Constant-product, StableSwap and the v4 custom curves built on them are all unbounded-range makers. Bringing a bounded-loss scoring rule to a two-sided token pool, with the bound published as a view a provider reads before depositing, is the contribution here.
 * @custom:limitation The range is finite by construction, so a pool whose true price leaves the band stops quoting on that side and holds the losing asset until the price returns; that is the bounded loss being collected, not a malfunction. It is the right curve for pairs expected to stay near a ratio and the wrong one for anything that can genuinely revalue. The maths runs through fixed-point exponentials, so a swap costs meaningfully more gas than constant product. And `b` is fixed at deployment: a pool that wants a different depth is a different pool.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract LMSRHook is ForgeCurveHook {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Fixed point one, signed, which is what the fixed-point library works in.
    int256 internal constant WAD = 1e18;

    /// @notice Fixed point one, unsigned, for the plain token arithmetic around the edges.
    uint256 internal constant WAD_UNSIGNED = 1e18;

    /**
     * @notice The largest exponent the curve will evaluate.
     * @dev A bound on the arithmetic, not a policy. Past this the reserves are so lopsided that the quote would be
     * dominated by rounding, and refusing is more honest than returning a number nobody should act on.
     */
    int256 internal constant MAX_EXPONENT = 40e18;

    /// @notice The liquidity parameter. Depth near parity, and the bound on what the curve can cost a provider.
    uint256 public immutable b;

    /// @notice The swap fee, in basis points, which stays in the reserves and therefore in every share.
    uint256 public immutable swapFeeBps;

    /// @dev A liquidity parameter of zero would make the curve a step function.
    error InvalidB();

    /// @dev A fee at or above the whole trade is not a fee.
    error InvalidFee();

    /// @dev The pool holds nothing on one side, so there is no curve to quote against.
    error NoReserves();

    /// @dev The reserves are too lopsided for the curve to quote. See {MAX_EXPONENT}.
    error OutOfRange();

    /// @dev The trade wants more than the curve will give up at any price.
    error InsufficientReserves();

    constructor(IPoolManager _poolManager, uint256 _b, uint256 _swapFeeBps, string memory name_, string memory symbol_)
        ForgeCurveHook(_poolManager, name_, symbol_)
    {
        if (_b == 0) revert InvalidB();
        if (_swapFeeBps >= 10_000) revert InvalidFee();
        b = _b;
        swapFeeBps = _swapFeeBps;
    }

    /**
     * @notice The most this curve can cost a provider, in units of either token.
     * @dev Hanson's bound for a two-outcome market, `b * ln(2)`. It is the whole reason to choose this curve over one
     * that quotes everywhere, and it is a view so nobody has to take it on trust from a document.
     */
    function maxLoss() public view returns (uint256) {
        // ln(2) in wad, to the precision the fixed-point library itself carries.
        return (b * 693_147_180_559_945_309) / uint256(WAD_UNSIGNED);
    }

    /// @notice The marginal price of one unit of currency0, in currency1, at the current reserves. Wad.
    function spotPrice() public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoReserves();
        return uint256(_priceOf(reserve0, reserve1).unwrap());
    }

    /// @dev exp((reserve1 - reserve0) / b), the slope of the invariant. One when the reserves are equal.
    function _priceOf(uint256 reserve0, uint256 reserve1) private view returns (SD59x18) {
        SD59x18 exponent = _ratio(reserve1, reserve0);
        return exponent.exp();
    }

    /**
     * @dev `exp(-amount / b)`, clamped to zero once the exponent is beyond what the library evaluates.
     *
     * The clamp is the mathematically correct answer rather than a fudge: the term is a decaying exponential and its
     * limit is exactly zero. Refusing instead, as the reserve ratio does, would mean a large enough trade reverted
     * where the honest reply is that it consumes essentially all the remaining depth.
     */
    function _decay(uint256 amount) private view returns (SD59x18) {
        int256 scaled = -((amount.toInt256() * WAD) / b.toInt256());
        if (scaled <= -MAX_EXPONENT) return sd(0);
        return sd(scaled).exp();
    }

    /// @dev `(x - y) / b` as a signed wad, refusing anything the exponential cannot evaluate meaningfully.
    function _ratio(uint256 x, uint256 y) private view returns (SD59x18) {
        int256 difference = x.toInt256() - y.toInt256();
        int256 scaled = (difference * WAD) / b.toInt256();
        if (scaled > MAX_EXPONENT || scaled < -MAX_EXPONENT) revert OutOfRange();
        return sd(scaled);
    }

    /**
     * @notice What the curve gives for `amountIn`, before the swap fee.
     *
     * @dev Solved in closed form from the invariant. Writing `A = exp(-reserveIn / b)` and `B = exp(-reserveOut / b)`,
     * holding `A + B` constant across the trade gives
     *
     *   amountOut = b * ln(1 + (B / A) * (1 - exp(-amountIn / b)))
     *
     * which is finite for every input, however large. That is the bound made concrete: no trade, at any size, can
     * take more than `b * ln(1 + B / A)` out of this pool.
     */
    function quoteGross(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        return _quoteFrom(reserveIn, reserveOut, amountIn);
    }

    /// @dev As {quoteGross}, from reserves the caller has already read.
    function _quoteFrom(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) private view returns (uint256) {
        if (reserveIn == 0 || reserveOut == 0) revert NoReserves();
        if (amountIn == 0) return 0;

        // B / A, which is exp((reserveIn - reserveOut) / b). Formed as one exponential rather than two, so a deep
        // pool never has to evaluate exp of a large negative number and lose the answer to rounding.
        SD59x18 ratio = _ratio(reserveIn, reserveOut).exp();

        // 1 - exp(-amountIn / b), the share of the remaining depth this trade consumes. Always in (0, 1].
        SD59x18 consumed = sd(WAD).sub(_decay(amountIn));

        SD59x18 grown = sd(WAD).add(ratio.mul(consumed));
        int256 out = (grown.ln().unwrap() * b.toInt256()) / WAD;
        if (out <= 0) return 0;

        uint256 amountOut = out.toUint256();
        if (amountOut >= reserveOut) revert InsufficientReserves();
        return amountOut;
    }

    /**
     * @dev The curve's answer with the fee applied in the direction the swap runs.
     *
     * On an exact-input swap the trader receives less than the curve quoted; on an exact-output swap they pay more.
     * Either way the difference stays in the reserves, which is what pays the providers.
     *
     * The exact-output branch inverts by solving the same closed form the other way, so the two directions cannot
     * disagree: a second schedule fitted to the first is a second schedule that will one day differ from it.
     */
    function _getUnspecifiedAmount(SwapParams calldata params) internal view override returns (uint256) {
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        (uint256 net,) = _quoteNet(params.zeroForOne, exactInput, specified);
        return net;
    }

    /// @dev The net amount and the fee taken, for one swap in one direction.
    function _quoteNet(bool zeroForOne, bool exactInput, uint256 specified)
        private
        view
        returns (uint256 net, uint256 fee)
    {
        (uint256 reserve0, uint256 reserve1) = reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        if (exactInput) {
            uint256 gross = _quoteFrom(reserveIn, reserveOut, specified);
            fee = (gross * swapFeeBps) / 10_000;
            net = gross - fee;
        } else {
            // The trader wants `specified` out net of the fee, so the curve has to give up the grossed-up amount.
            uint256 gross = (specified * 10_000 + (10_000 - swapFeeBps) - 1) / (10_000 - swapFeeBps);
            uint256 required = _requiredInput(reserveIn, reserveOut, gross);
            fee = gross - specified;
            net = required;
        }
    }

    /**
     * @dev The input that yields exactly `amountOut`, inverting the closed form.
     *
     *   amountIn = -b * ln(1 - (A / B) * (exp(amountOut / b) - 1))
     *
     * Rounded up by one wei, so an exact-output trade never rounds in the trader's favour against the reserves.
     */
    function _requiredInput(uint256 reserveIn, uint256 reserveOut, uint256 amountOut)
        private
        view
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0) revert NoReserves();
        if (amountOut == 0) return 0;
        if (amountOut >= reserveOut) revert InsufficientReserves();

        SD59x18 inverse = _ratio(reserveOut, reserveIn).exp();
        SD59x18 grown = _ratio(amountOut, 0).exp().sub(sd(WAD));
        SD59x18 remaining = sd(WAD).sub(inverse.mul(grown));
        // A non-positive remainder means the curve cannot reach that output at any input.
        if (remaining.unwrap() <= 0) revert InsufficientReserves();

        int256 needed = -(remaining.ln().unwrap() * b.toInt256()) / WAD;
        if (needed <= 0) return 1;
        return needed.toUint256() + 1;
    }

    /**
     * @dev Reports the fee {_getUnspecifiedAmount} already applied, for the base contract's event.
     * @dev The unspecified amount arrives net, so the gross is recovered before the fee is taken off it. A fee
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
        if (exactInput) {
            uint256 gross = (unspecifiedAmount * 10_000) / (10_000 - swapFeeBps);
            return gross - unspecifiedAmount;
        }
        uint256 specified = uint256(params.amountSpecified);
        uint256 grossed = (specified * 10_000 + (10_000 - swapFeeBps) - 1) / (10_000 - swapFeeBps);
        return grossed - specified;
    }

    function hookName() external pure override returns (string memory) {
        return "LMSR";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "lmsr.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "custom-curve";
        tags[2] = "bounded-loss";
        tags[3] = "scoring-rule";
        tags[4] = "no-admin";
    }
}
