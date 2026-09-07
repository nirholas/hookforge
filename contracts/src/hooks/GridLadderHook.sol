// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeCurveHook} from "../base/ForgeCurveHook.sol";

/**
 * @title GridLadderHook
 * @notice A pool that quotes a bid and an ask, like a market maker, instead of one price both ways.
 *
 * @dev Every AMM curve has a single price at any moment, and both sides of the market trade against it. That is the
 * defining simplification of the design, and it means a pool cannot express the one thing a quoting desk exists to
 * express: I will buy at this, and sell at that, and the gap between them is what I am paid.
 *
 * The gap is not the same thing as a fee. A fee is symmetric and proportional; a spread is a position. A desk that is
 * long and wants to get flat quotes a keen bid and a wide ask, and it does that by moving the two sides
 * independently. An AMM with a fee cannot say that at all: raising the fee makes it less willing to trade in both
 * directions equally, which is exactly not what the desk wanted.
 *
 * This pool holds two ladders. The bid ladder is what it pays for currency0, the ask ladder is what it charges, and
 * each has its own base price, its own increment and its own band width. Set them symmetrically and it behaves like
 * an ordinary stepped pool with a spread. Set them apart and the pool leans: keen on one side, wide on the other,
 * which is a resting position rather than a fee schedule.
 *
 * Both ladders step with inventory, so the pool also becomes less willing to keep going the way it is already
 * leaning, which is the same self-correction any inventory-aware desk applies.
 *
 * The spread is the providers' revenue and it never leaves the reserves, so there is no separate fee parameter: a
 * swap that crosses the spread simply hands the pool more than the mid, and the shares are a claim on reserves that
 * grew. Setting `askBaseX96` equal to `bidBaseX96` makes the pool free to trade and is allowed, because refusing it
 * would be an opinion rather than a safety property.
 *
 * @custom:slug grid-ladder
 * @custom:family Curves
 * @custom:prior-art Bancor's Carbon quotes independent, asymmetric bid and ask curves and is the direct ancestor of this idea, off v4 and as per-user strategies rather than a pool. Uniswap v4's own range orders express one side at a time. A single fungible v4 pool that quotes two independent inventory-stepped ladders, so providers share one book with a real spread, is the contribution here.
 * @custom:limitation Two ladders mean the pool is not a conservative curve: there is no single invariant a swap preserves, so the usual arbitrage-free reasoning about constant-function market makers does not apply, and a badly configured spread can be crossed for a loss. The bands are also fixed at deployment, so a pool whose asset leaves the configured range stops quoting on that side. It is a market maker's tool and it wants a market maker's attention.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract GridLadderHook is ForgeCurveHook {
    /// @notice Fixed point one, in the Q96 format prices are quoted in.
    uint256 internal constant Q96 = 1 << 96;

    /// @notice The most bands one swap may cross, so a large swap is bounded rather than an unbounded loop.
    uint256 public constant MAX_STEPS = 256;

    /// @notice One side of the book.
    struct Ladder {
        /// @notice Price at the top of this ladder, in currency1 per currency0. Q96.
        uint256 baseX96;
        /// @notice How much the price moves per band. Q96.
        uint256 stepX96;
        /// @notice The price this ladder bottoms out at. Q96.
        uint256 floorX96;
        /// @notice Width of one band, in units of currency0.
        uint256 bandSize;
    }

    /// @notice What the pool pays for currency0.
    Ladder public bid;

    /// @notice What the pool charges for currency0. Never below the bid at the same inventory.
    Ladder public ask;

    /// @dev A ladder was configured with a zero band, a zero price, or a floor above its base.
    error InvalidLadder();

    /// @dev The ask must be at or above the bid at every inventory, or the pool pays people to round-trip it.
    error CrossedBook();

    /// @dev The swap would cross more than `MAX_STEPS` bands.
    error SwapTooLarge();

    /// @dev The pool has run out of the currency being bought.
    error InsufficientReserves();

    /// @dev A quote was requested against an empty pool.
    error NoLiquidity();

    constructor(
        IPoolManager _poolManager,
        Ladder memory _bid,
        Ladder memory _ask,
        string memory shareName,
        string memory shareSymbol
    ) ForgeCurveHook(_poolManager, shareName, shareSymbol) {
        _validate(_bid);
        _validate(_ask);
        // Checked at the top of the book and at the bottom. Both ladders fall monotonically, so if the ask is at or
        // above the bid at each end it is at or above it throughout.
        if (_ask.baseX96 < _bid.baseX96 || _ask.floorX96 < _bid.floorX96) revert CrossedBook();

        bid = _bid;
        ask = _ask;
    }

    function _validate(Ladder memory ladder) private pure {
        if (ladder.bandSize == 0 || ladder.baseX96 == 0 || ladder.floorX96 == 0) revert InvalidLadder();
        if (ladder.floorX96 > ladder.baseX96) revert InvalidLadder();
    }

    /// @dev A ladder's price at a given inventory of currency0.
    function _priceAt(Ladder memory ladder, uint256 reserve0) private pure returns (uint256) {
        // The division precedes the multiplication deliberately: flooring the reserve to a whole band is the
        // mechanism, and reordering would make the ladder continuous.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 fall = (reserve0 / ladder.bandSize) * ladder.stepX96;
        if (fall >= ladder.baseX96 - ladder.floorX96) return ladder.floorX96;
        return ladder.baseX96 - fall;
    }

    /**
     * @notice What the pool would pay for currency0 if it held `reserve0` of it. Q96.
     * @dev Exposed at an arbitrary inventory, not just the current one, because the whole book is the thing a market
     * maker wants to see: where the pool will be bidding after it has absorbed the next hundred units matters more
     * than where it is bidding now.
     */
    function bidAtX96(uint256 reserve0) public view returns (uint256) {
        return _priceAt(bid, reserve0);
    }

    /// @notice What the pool would charge for currency0 if it held `reserve0` of it. Q96.
    function askAtX96(uint256 reserve0) public view returns (uint256) {
        return _priceAt(ask, reserve0);
    }

    /// @notice What the pool currently pays for currency0. Q96.
    function currentBidX96() external view returns (uint256) {
        return _priceAt(bid, reserve(poolKey().currency0));
    }

    /// @notice What the pool currently charges for currency0. Q96.
    function currentAskX96() external view returns (uint256) {
        return _priceAt(ask, reserve(poolKey().currency0));
    }

    /// @notice The spread the pool is quoting right now, in Q96 price units.
    function currentSpreadX96() external view returns (uint256) {
        uint256 reserve0 = reserve(poolKey().currency0);
        return _priceAt(ask, reserve0) - _priceAt(bid, reserve0);
    }

    /**
     * @notice What a swap pays or costs. The spread is the pool's revenue, so there is no separate fee to net off.
     * @param zeroForOne True to sell currency0 into the pool, which fills against the bid ladder.
     * @param exactInput True when `specifiedAmount` is what the trader pays.
     */
    function quote(bool zeroForOne, bool exactInput, uint256 specifiedAmount) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        if (reserve0 == 0 || reserve1 == 0) revert NoLiquidity();

        // Selling currency0 fills against the bid; buying it fills against the ask.
        return zeroForOne
            ? _walkSell(bid, reserve0, reserve1, exactInput, specifiedAmount)
            : _walkBuy(ask, reserve0, exactInput, specifiedAmount);
    }

    /// @dev Selling currency0 into the pool: inventory rises, so the ladder walks down.
    function _walkSell(Ladder memory ladder, uint256 reserve0, uint256 reserve1, bool exactInput, uint256 specified)
        private
        pure
        returns (uint256)
    {
        uint256 r0 = reserve0;
        uint256 remaining = specified;
        uint256 accumulated;

        for (uint256 i = 0; i < MAX_STEPS; i++) {
            if (remaining == 0) return accumulated;

            uint256 price = _priceAt(ladder, r0);
            uint256 room = ladder.bandSize - (r0 % ladder.bandSize);

            if (exactInput) {
                uint256 take = remaining < room ? remaining : room;
                uint256 out = (take * price) / Q96;
                if (out > reserve1 - accumulated) revert InsufficientReserves();
                accumulated += out;
                r0 += take;
                remaining -= take;
            } else {
                uint256 bandOut = (room * price) / Q96;
                if (remaining <= bandOut) {
                    // Rounded up, so the trader never underpays for the output they asked for.
                    return accumulated + (remaining * Q96 + price - 1) / price;
                }
                accumulated += room;
                r0 += room;
                remaining -= bandOut;
            }
        }
        revert SwapTooLarge();
    }

    /// @dev Buying currency0 out of the pool: inventory falls, so the ladder walks up.
    function _walkBuy(Ladder memory ladder, uint256 reserve0, bool exactInput, uint256 specified)
        private
        pure
        returns (uint256)
    {
        uint256 r0 = reserve0;
        uint256 remaining = specified;
        uint256 accumulated;

        for (uint256 i = 0; i < MAX_STEPS; i++) {
            if (remaining == 0) return accumulated;
            if (r0 == 0) revert InsufficientReserves();

            uint256 position = r0 % ladder.bandSize;
            uint256 room = position == 0 ? ladder.bandSize : position;
            if (room > r0) room = r0;

            uint256 price = _priceAt(ladder, r0 - 1);
            if (price == 0) revert InvalidLadder();

            if (exactInput) {
                uint256 bandCost = (room * price) / Q96;
                if (remaining < bandCost) return accumulated + (remaining * Q96) / price;
                accumulated += room;
                r0 -= room;
                remaining -= bandCost;
            } else {
                uint256 take = remaining < room ? remaining : room;
                if (take > r0) revert InsufficientReserves();
                accumulated += (take * price + Q96 - 1) / Q96;
                r0 -= take;
                remaining -= take;
            }
        }
        revert SwapTooLarge();
    }

    /// @dev Quotes the swap against whichever side of the book it hits.
    function _getUnspecifiedAmount(SwapParams calldata params) internal view override returns (uint256) {
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        return quote(params.zeroForOne, exactInput, specified);
    }

    /**
     * @dev No separate fee: the spread is the revenue and it is already inside the quote.
     *
     * Reporting zero here is honest rather than lazy. The base contract's event describes a fee taken out of a swap,
     * and this pool takes none; what it earns is the difference between the two ladders, which is visible in the
     * reserves and in {currentSpreadX96} rather than as a deduction.
     */
    function _getSwapFeeAmount(SwapParams calldata, uint256) internal pure override returns (uint256) {
        return 0;
    }

    function hookName() external pure override returns (string memory) {
        return "GridLadder";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "grid-ladder.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "custom-curve";
        tags[2] = "market-making";
        tags[3] = "spread";
        tags[4] = "inventory";
    }
}
