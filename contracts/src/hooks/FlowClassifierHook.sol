// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {IFlowStats} from "../interfaces/IFlowStats.sol";
import {Saturating} from "../libraries/Saturating.sol";

/**
 * @title FlowClassifierHook
 * @notice Publishes, on-chain, how much of a pool's order flow arrives first in the block and how far it moves the
 * price when it does. It changes nothing about the pool it measures.
 *
 * @dev Almost every fee mechanism in this catalogue is a guess about who is trading. The staleness tax guesses from
 * elapsed time. The priority-fee tax guesses from what a trade bid for its position. Each one re-derives the same
 * hidden quantity privately, none of them publishes it, and no two of them agree.
 *
 * The quantity they are all reaching for has a clean on-chain signature. Arbitrage arrives first in its block, because
 * being second is worthless when the whole trade is closing a gap somebody else can close instead. Ordinary flow does
 * not care where in a block it lands. So the split between swaps that led their block and swaps that followed one is a
 * measurable proxy for the split between informed and uninformed flow, and the ratio of how far each population moves
 * the price is a measure of how expensive the informed half is.
 *
 * This hook counts both and publishes them through {IFlowStats}:
 *
 *   - `leadShareBps`: the fraction of swaps that were first in their block.
 *   - `leadImpactRatioBps`: how much further the average leading swap moves the price than the average following one.
 *     `10_000` means they move it equally. A pool being arbitraged reads well above that.
 *
 * The point is that it is a public good rather than a mechanism. It sets no fee, returns no delta, takes no payment
 * and rejects nothing; a test asserts that a swap through a measured pool receives exactly what the same swap through
 * an identical unhooked pool receives. Other hooks can price from it, routers can prefer pools whose flow is cheap to
 * fill, providers can decide whether a pool is worth quoting, and indexers can rank pools by something more
 * meaningful than volume.
 *
 * Counters saturate rather than wrap. A wrapped counter reports a small number where a huge one belongs and every
 * ratio derived from it becomes quietly wrong; a saturated one stops moving and keeps the last true value, which is a
 * failure a reader can notice.
 *
 * @custom:slug flow-classifier
 * @custom:family Order flow and MEV
 * @custom:prior-art Off-chain, order-flow toxicity is standard: VPIN, markout, and the lead-lag analysis every market maker runs on its own fills. On-chain, hooks consume such signals privately to set a fee. Publishing the measurement itself, from a hook that deliberately does nothing else, so that every other contract can read one pool's flow quality instead of each guessing at it, is the contribution here.
 * @custom:limitation First-in-block is a proxy, not a fact. A private-mempool arbitrage that lands second still leads economically, and an ordinary swap that happens to be first is counted as leading. The measure is meaningful in aggregate over many blocks and says nothing reliable about any single swap. On a chain with sub-second blocks where most blocks hold one swap, nearly everything leads and the ratio degenerates.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract FlowClassifierHook is ForgeHook, IFlowStats {
    using StateLibrary for IPoolManager;
    using Saturating for uint32;
    using Saturating for uint64;

    /// @notice Everything measured about one pool. Packs into two slots.
    struct Stats {
        /// @notice Every swap the pool has seen.
        uint32 swaps;
        /// @notice Swaps that were the first this pool saw in their block.
        uint32 leadSwaps;
        /// @notice Cumulative absolute tick movement caused by leading swaps.
        uint64 leadTicks;
        /// @notice Cumulative absolute tick movement caused by every other swap.
        uint64 followTicks;
        /// @notice The last block in which this pool traded, so the next block's first swap is recognised.
        uint64 lastBlock;
    }

    /// @notice The measurement in progress: where the price was before the swap now executing, and its classification.
    struct Pending {
        int24 tickBefore;
        bool isLead;
    }

    /// @notice Published statistics per pool.
    mapping(PoolId => Stats) private _stats;

    /// @notice The swap currently between `beforeSwap` and `afterSwap`, per pool.
    mapping(PoolId => Pending) private _pending;

    /// @notice Emitted for every swap measured, so the series can be reconstructed without replaying state.
    event FlowObserved(PoolId indexed id, bool lead, uint256 ticksMoved);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @inheritdoc IFlowStats
    function flowStats(PoolId id)
        external
        view
        returns (uint256 swaps, uint256 leadSwaps, uint256 leadTicks, uint256 followTicks)
    {
        Stats memory stats = _stats[id];
        return (stats.swaps, stats.leadSwaps, stats.leadTicks, stats.followTicks);
    }

    /// @inheritdoc IFlowStats
    function leadShareBps(PoolId id) external view returns (uint256) {
        Stats memory stats = _stats[id];
        if (stats.swaps == 0) return 0;
        return (uint256(stats.leadSwaps) * 10_000) / stats.swaps;
    }

    /// @inheritdoc IFlowStats
    function leadImpactRatioBps(PoolId id) external view returns (uint256) {
        Stats memory stats = _stats[id];
        uint256 followSwaps = uint256(stats.swaps) - stats.leadSwaps;
        // A ratio needs both populations. With only one, there is nothing to compare and the honest answer is none.
        if (stats.leadSwaps == 0 || followSwaps == 0 || stats.followTicks == 0) return 0;

        uint256 averageLead = uint256(stats.leadTicks) / stats.leadSwaps;
        uint256 averageFollow = uint256(stats.followTicks) / followSwaps;
        if (averageFollow == 0) return 0;
        return (averageLead * 10_000) / averageFollow;
    }

    /**
     * @dev Records where the price stood and whether this swap leads its block.
     *
     * Returns a zero delta and no fee override, so the pool prices the swap exactly as it would with no hook at all.
     * That is the property that makes this safe to attach to a pool somebody else is running.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tick,,) = poolManager.getSlot0(id);

        _pending[id] = Pending({tickBefore: tick, isLead: _stats[id].lastBlock != uint64(block.number)});
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Measures how far the swap moved the price and files it under the population it belongs to.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tickAfter,,) = poolManager.getSlot0(id);

        Pending memory pending = _pending[id];
        int256 moved = int256(tickAfter) - int256(pending.tickBefore);
        // Both casts are safe: `moved` is the difference of two int24 ticks, so it is far inside int256 and the
        // branch fixes its sign before each conversion.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ticks = moved < 0 ? uint256(-moved) : uint256(moved);

        Stats memory stats = _stats[id];
        stats.swaps = stats.swaps.inc32();
        if (pending.isLead) {
            stats.leadSwaps = stats.leadSwaps.inc32();
            stats.leadTicks = stats.leadTicks.add64(ticks);
        } else {
            stats.followTicks = stats.followTicks.add64(ticks);
        }
        // Casting to 'uint64' is safe because no chain will reach block 18 quintillion.
        // forge-lint: disable-next-line(unsafe-typecast)
        stats.lastBlock = uint64(block.number);
        _stats[id] = stats;

        emit FlowObserved(id, pending.isLead, ticks);
        return (this.afterSwap.selector, 0);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IFlowStats).interfaceId || super.supportsInterface(interfaceId);
    }

    function hookName() external pure override returns (string memory) {
        return "FlowClassifier";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "flow-classifier.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "mev";
        tags[1] = "public-good";
        tags[2] = "analytics";
        tags[3] = "order-flow";
        tags[4] = "oracle-free";
    }
}
