// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ChainlinkSqrtPriceAdapter, IAggregatorV3} from "src/adapters/ChainlinkSqrtPriceAdapter.sol";
import {TestAggregator} from "./doubles/TestAggregator.sol";

contract ChainlinkSqrtPriceAdapterTest is Test {
    TestAggregator internal feed;

    // A pool holding an 18-decimal asset as currency0 and a 6-decimal one as currency1, priced by an 8-decimal feed.
    uint8 internal constant D0 = 18;
    uint8 internal constant D1 = 6;
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant PRICE = 3000e8; // 3000 currency1 per currency0

    function setUp() public {
        // A realistic wall clock, so tests can look backwards without underflowing block.timestamp.
        vm.warp(1_800_000_000);
        feed = new TestAggregator(FEED_DECIMALS, PRICE);
    }

    /// @dev Recovers the human price from the returned sqrtPriceX96 and checks it against the feed, which is the
    /// property that actually matters: it fails on any decimal error, in either direction.
    function _recoverPrice(uint160 sqrtPriceX96) internal pure returns (uint256 priceScaled) {
        uint256 ratioX192 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1);
        // price (currency1 per currency0, human units) = ratio * 10**D0 / 10**D1, then scaled by the feed's decimals.
        uint256 humanX192 = FullMath.mulDiv(ratioX192, 10 ** D0 * 10 ** FEED_DECIMALS, 10 ** D1);
        return humanX192 >> 192;
    }

    function test_convertsAFeedPriceIntoAPoolPrice() public {
        ChainlinkSqrtPriceAdapter adapter = new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(feed)), D0, D1, false);
        (uint160 price, uint256 updatedAt) = adapter.sqrtPriceX96();

        assertGt(price, 0);
        assertEq(updatedAt, block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertApproxEqRel(_recoverPrice(price), uint256(PRICE), 1e12, "recovered price must match the feed");
    }

    function test_invertedFeedGivesTheSamePoolPrice() public {
        ChainlinkSqrtPriceAdapter direct = new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(feed)), D0, D1, false);

        // A feed quoting the pair the other way round: currency0 per currency1, at 1/3000, in 18 decimals so the
        // reciprocal keeps enough significant figures to compare against the direct quote.
        int256 reciprocalAnswer = int256(uint256(1e18) * 1e18 / uint256(3000e18));
        TestAggregator reciprocal = new TestAggregator(18, reciprocalAnswer);
        ChainlinkSqrtPriceAdapter inverted =
            new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(reciprocal)), D0, D1, true);

        (uint160 a,) = direct.sqrtPriceX96();
        (uint160 b,) = inverted.sqrtPriceX96();
        assertApproxEqRel(uint256(b), uint256(a), 1e12, "inverting the quote must not move the price");
    }

    function test_tracksTheFeed() public {
        ChainlinkSqrtPriceAdapter adapter = new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(feed)), D0, D1, false);
        (uint160 before,) = adapter.sqrtPriceX96();

        feed.set(PRICE * 4);
        (uint160 later,) = adapter.sqrtPriceX96();

        // Four times the price is twice the square root of the price.
        assertApproxEqRel(uint256(later), uint256(before) * 2, 1e12);
    }

    function test_reportsWhenTheFeedLastPublished() public {
        ChainlinkSqrtPriceAdapter adapter = new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(feed)), D0, D1, false);
        feed.setUpdatedAt(block.timestamp - 900);

        (, uint256 updatedAt) = adapter.sqrtPriceX96();
        assertEq(updatedAt, block.timestamp - 900, "staleness is the caller's policy, so the timestamp is passed on");
    }

    function test_nonPositiveAnswer_reverts() public {
        ChainlinkSqrtPriceAdapter adapter = new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(feed)), D0, D1, false);

        feed.set(0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSqrtPriceAdapter.InvalidAnswer.selector, int256(0)));
        adapter.sqrtPriceX96();

        feed.set(-1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkSqrtPriceAdapter.InvalidAnswer.selector, int256(-1)));
        adapter.sqrtPriceX96();
    }

    function testFuzz_priceIsMonotoneInTheFeed(uint96 low, uint96 high) public {
        low = uint96(bound(low, 1e6, 1e24));
        high = uint96(bound(high, uint256(low), 1e26));

        ChainlinkSqrtPriceAdapter adapter = new ChainlinkSqrtPriceAdapter(IAggregatorV3(address(feed)), D0, D1, false);

        feed.set(int256(uint256(low)));
        (uint160 a,) = adapter.sqrtPriceX96();
        feed.set(int256(uint256(high)));
        (uint160 b,) = adapter.sqrtPriceX96();

        assertGe(b, a);
    }
}
