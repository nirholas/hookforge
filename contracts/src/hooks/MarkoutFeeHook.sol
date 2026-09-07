// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title MarkoutFeeHook
 * @notice A fee that learns. The pool measures whether its own past trades turned out to be informed, and charges the
 * next one accordingly.
 *
 * @dev Every dynamic-fee hook published so far prices a swap from something observable at the moment it arrives: the
 * size, the recent volatility, the gas it bid, the distance from an oracle. All of those are proxies for the question
 * that actually matters, which is whether the person on the other side knew something. None of them measure it,
 * because at the moment a swap arrives that fact has not happened yet.
 *
 * It has happened a few seconds later. If a swap pushed the price down and the price kept falling, the seller was
 * right and the liquidity that filled them lost; that is an informed trade, and it is the cost the LP literature calls
 * adverse selection. If the price came back, the swap was noise and the fee it paid was pure revenue. This is the
 * markout that every market maker computes on their own flow, and a pool has everything needed to compute it: the tick
 * it was left at, and the tick it is at now.
 *
 * So this hook grades each swap after the fact. On the next swap it compares the current tick to the tick the previous
 * swap left behind, decides whether that swap was informed, and folds the verdict into an exponentially weighted
 * average. The fee it quotes is:
 *
 *   fee = baseFee + maxSurcharge * toxicity
 *
 * A pool whose flow is mostly retail converges toward `baseFee` and becomes cheap. A pool being picked off converges
 * toward the cap and becomes expensive, without anybody deciding that, and without an oracle to manipulate or a
 * governance process to capture. The score is public, so anything else on-chain can read a pool's measured toxicity
 * rather than guessing at it.
 *
 * Two details keep the measurement honest. A verdict is only recorded once `minHorizon` seconds have passed, because
 * a comparison inside the same block is measuring the swap's own price impact rather than what happened next. And the
 * verdict is graded by magnitude rather than treated as a coin flip: a move that continues by a tenth of a tick is
 * weak evidence, a move that continues by a hundred ticks is strong, so the observation is scaled and clamped instead
 * of being rounded to a yes or a no.
 *
 * {FlowClassifierHook} measures a related quantity and deliberately does nothing with it; this hook is the other
 * half of that pair, the one that acts on what it measures.
 *
 * The hook takes no fee for itself, custodies nothing, and has no privileged role. `baseFee`, the cap, the smoothing
 * and the horizon are fixed before the pool exists and can never be changed.
 *
 * @custom:slug markout-fee
 * @custom:family Order flow and MEV
 * @custom:prior-art Dynamic fees keyed on realized volatility, swap size, price movement or an oracle gap are all well covered, and markout is the standard way a market maker grades its own flow off-chain. Computing markout on-chain, from the pool's own tick history, and feeding it back as the pool's fee, is the contribution here. It is the difference between reacting to a proxy for adverse selection and measuring the thing itself.
 * @custom:limitation The verdict on a swap arrives with the next swap, so a pool that trades once a day prices today's flow on yesterday's evidence, and a pool with no second swap never grades the first. It is a lagging signal by construction: a regime change is paid for at the old rate until the average catches up. Note also that a sustained one-directional run grades as informed, because every swap in it is followed by one pushing the same way. That is the intended reading rather than a flaw, but it does mean a pool tracking a strong trend will quote its trend-following flow expensively even when that flow is not picking anyone off.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract MarkoutFeeHook is ForgeFeeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Fixed-point one, for the toxicity score and the smoothing factor.
    uint256 internal constant WAD = 1e18;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Fee charged when measured toxicity is zero, in hundredths of a bip.
        uint24 baseFee;
        /// @notice Additional fee at a toxicity of one, in hundredths of a bip.
        uint24 maxSurcharge;
        /// @notice EWMA smoothing factor in WAD. 0.1e18 weights each new verdict at 10%.
        uint64 alphaWad;
        /// @notice Seconds that must pass before a swap can be graded. Below this the move is the swap's own impact.
        uint32 minHorizon;
        /// @notice Tick continuation treated as a fully informed trade. Larger moves are clamped to it.
        uint24 saturationTicks;
    }

    /// @notice What the pool remembers about the last swap, so the next one can grade it.
    struct Mark {
        /// @notice Tick the previous swap left the pool at.
        int24 tick;
        /// @notice When it happened.
        uint64 timestamp;
        /// @notice Direction it pushed the price. True means it sold currency0 and pushed the tick down.
        bool zeroForOne;
        /// @notice Whether there is a swap here to grade at all.
        bool present;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The unfinished measurement for each pool.
    mapping(PoolId => Mark) public markOf;

    /// @notice Measured share of flow that turned out to be informed, in WAD. Public: anything may read it.
    mapping(PoolId => uint256) public toxicityOf;

    /// @notice How many swaps have been graded, so a reader can tell a settled score from a fresh one.
    mapping(PoolId => uint64) public gradedCount;

    /// @dev `alphaWad` must be in (0, 1e18]: zero never learns, above one overshoots.
    error InvalidSmoothing();

    /// @dev `saturationTicks` of zero would make every move maximally informed.
    error InvalidSaturation();

    /// @dev `baseFee + maxSurcharge` must leave room under the 100% protocol maximum.
    error SurchargeTooLarge();

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 baseFee, uint24 maxSurcharge, uint64 alphaWad, uint32 minHorizon);

    /// @notice Emitted whenever a past swap is graded, with the evidence and the resulting score.
    event FlowGraded(PoolId indexed id, int256 continuationTicks, uint256 observationWad, uint256 toxicityWad);

    /// @notice Emitted on every swap with the fee the measured toxicity produced.
    event FlowPriced(PoolId indexed id, uint256 toxicityWad, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.alphaWad == 0 || cfg.alphaWad > WAD) revert InvalidSmoothing();
        if (cfg.saturationTicks == 0) revert InvalidSaturation();
        FeeMath.requireValid(cfg.baseFee);
        if (uint256(cfg.baseFee) + cfg.maxSurcharge > 1_000_000) revert SurchargeTooLarge();

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.baseFee, cfg.maxSurcharge, cfg.alphaWad, cfg.minHorizon);
    }

    /// @notice The fee this pool charges right now, given everything it has measured so far.
    function quoteFee(PoolId id) public view returns (uint24) {
        Config memory cfg = configOf[id];
        return FeeMath.addClamped(cfg.baseFee, FeeMath.mulDiv(cfg.maxSurcharge, toxicityOf[id], WAD));
    }

    /**
     * @notice Grades the previous swap against the price as it stands right now, without writing anything.
     * @dev The pool grades a swap when the *next* swap lands, so between swaps this returns the verdict that swap
     * would receive if it arrived at the current price. It is a view onto the pending measurement, not the one that
     * will necessarily be recorded.
     * @return observationWad How informed the previous swap looks, in WAD. Zero when there is nothing to grade yet.
     * @return gradeable Whether enough time has passed for the comparison to mean anything.
     */
    function previewGrade(PoolId id) public view returns (uint256 observationWad, bool gradeable) {
        Mark memory mark = markOf[id];
        Config memory cfg = configOf[id];
        if (!mark.present) return (0, false);
        // Same reasoning as in `_afterSwap`: seconds of proposer drift cannot make this verdict wrong.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(mark.timestamp) + cfg.minHorizon) return (0, false);

        (, int24 currentTick,,) = poolManager.getSlot0(id);
        return (_observe(mark, currentTick, cfg.saturationTicks), true);
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].alphaWad == 0) revert PoolNotConfigured();
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /// @dev Prices this swap from everything graded so far. Grading itself happens in `_afterSwap`.
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        uint24 fee = quoteFee(id);
        emit FlowPriced(id, toxicityOf[id], fee);
        return fee;
    }

    /**
     * @dev Grades the previous swap against where this one left the price, then records this swap as the next mark.
     *
     * The grading has to happen here rather than before the swap, because in an AMM the price only moves when somebody
     * trades. "What happened next" after a swap is literally the next swap, so a comparison taken before that next
     * swap executes is always measuring a move of exactly zero.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        (, int24 tick,,) = poolManager.getSlot0(id);

        Mark memory mark = markOf[id];
        // Horizons are seconds to minutes, and a longer wait only makes the comparison more meaningful, so proposer
        // drift can make a verdict slightly early or late but never wrong.
        // forge-lint: disable-next-line(block-timestamp)
        if (mark.present && block.timestamp >= uint256(mark.timestamp) + cfg.minHorizon) {
            uint256 observation = _observe(mark, tick, cfg.saturationTicks);
            uint256 previous = toxicityOf[id];
            // Standard EWMA: new = previous + alpha * (observation - previous), in WAD.
            uint256 updated = observation >= previous
                ? previous + FeeMath.mulDiv(observation - previous, cfg.alphaWad, WAD)
                : previous - FeeMath.mulDiv(previous - observation, cfg.alphaWad, WAD);

            toxicityOf[id] = updated;
            gradedCount[id] += 1;

            int256 moved = int256(tick) - int256(mark.tick);
            emit FlowGraded(id, mark.zeroForOne ? -moved : moved, observation, updated);
        }

        markOf[id] =
            Mark({tick: tick, timestamp: uint64(block.timestamp), zeroForOne: params.zeroForOne, present: true});
        return (this.afterSwap.selector, 0);
    }

    /// @dev How informed `mark` looks, given the pool ended up at `tick`. Zero when the price came back.
    function _observe(Mark memory mark, int24 tick, uint24 saturationTicks) private pure returns (uint256) {
        // Continuation is movement in the direction the graded swap pushed. A zeroForOne swap pushes the tick down,
        // so the price continuing means the tick fell further.
        int256 moved = int256(tick) - int256(mark.tick);
        int256 continuation = mark.zeroForOne ? -moved : moved;
        if (continuation <= 0) return 0; // The price came back: the swap was noise, and noise scores zero.

        // Casting to 'uint256' is safe because the line above returned unless `continuation > 0`.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 magnitude = uint256(continuation);
        return magnitude >= saturationTicks ? WAD : (magnitude * WAD) / saturationTicks;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
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

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "MarkoutFee";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "markout-fee.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "mev";
        tags[1] = "dynamic-fee";
        tags[2] = "markout";
        tags[3] = "adverse-selection";
        tags[4] = "oracle-free";
    }
}
