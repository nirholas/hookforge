// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title ArbTaxDecayHook
 * @notice Prices the staleness of a pool: the longer a pool goes untraded, the more the next swap pays.
 *
 * @dev Loss-versus-rebalancing is the dominant cost of providing liquidity to a constant-function AMM. It is paid when
 * an arbitrageur brings a stale pool price back to the market price, and the size of that arbitrage grows with how
 * long the pool sat unpriced. Ordinary flow does not have this property: a swap that lands one second after another
 * swap is almost certainly not an arbitrage, because there was no time for the reference price to drift.
 *
 * This hook turns that observation into a fee. It measures the time since the pool last traded and adds a surcharge
 * that grows with it along a saturating curve, capped at `maxSurcharge`:
 *
 *   surcharge(elapsed) = maxSurcharge * elapsed / (elapsed + halfLife)
 *
 * At `elapsed == halfLife` the arbitrageur pays half the cap; a swap in the same second as the previous one pays only
 * `baseFee`. The surcharge is an LP fee, so the value it captures is paid to in-range liquidity providers. The hook
 * never custodies funds and holds no privileged role.
 *
 * Two properties make this cheap to reason about. It needs no oracle, so there is nothing to manipulate and no
 * liveness dependency. And it is monotone in a quantity the arbitrageur cannot control: waiting longer to arbitrage a
 * pool only raises the toll, so the strategy that minimizes the tax is to trade the pool more often, which is exactly
 * the behaviour that keeps the price fresh for everyone else.
 *
 * Prior art: dynamic-fee hooks keyed on realized volatility or on price movement are common, and the LVR literature
 * (Milionis, Moallemi, Roughgarden, Zhang) motivates charging arbitrageurs more. Keying the fee on time-since-last-
 * trade rather than on a price signal is the part that is new here, and it is what removes the oracle.
 *
 * Limitation, stated plainly: on a pool that trades continuously the surcharge is near zero, so this hook does nothing
 * for a busy major pair. It is aimed at the long tail, where pools are quiet for minutes or hours at a time and the
 * arbitrage on the first trade back is the whole of the LP's loss.
 *
 * @custom:slug arb-tax-decay
 * @custom:family Order flow and MEV
 * @custom:prior-art Dynamic-fee hooks keyed on realized volatility or on price movement are common, and the loss-versus-rebalancing literature (Milionis, Moallemi, Roughgarden, Zhang) motivates charging arbitrageurs more. Keying the fee on time since the last trade rather than on a price signal is what is new here, and it is what removes the oracle.
 * @custom:limitation On a pool that trades continuously the surcharge is near zero, so this does nothing for a busy major pair. It is aimed at the long tail, where pools sit quiet for minutes or hours and the arbitrage on the first trade back is the whole of the provider loss.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract ArbTaxDecayHook is ForgeFeeHook, PoolConfigurable {
    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Fee charged when the pool traded in the same second, in hundredths of a bip.
        uint24 baseFee;
        /// @notice Maximum surcharge added on top of `baseFee`, in hundredths of a bip.
        uint24 maxSurcharge;
        /// @notice Seconds of quiet at which half of `maxSurcharge` applies. Must be non-zero.
        uint32 halfLife;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice Timestamp of the most recent swap (or of initialization, before the first swap).
    mapping(PoolId => uint64) public lastTradeAt;

    /// @dev `halfLife` was zero, which would make every swap pay the full surcharge.
    error InvalidHalfLife();

    /// @dev `baseFee + maxSurcharge` must leave room under the 100% protocol maximum.
    error SurchargeTooLarge();

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 baseFee, uint24 maxSurcharge, uint32 halfLife);

    /// @notice Emitted on every swap with the staleness that was priced and the fee that resulted.
    event StalenessPriced(PoolId indexed id, uint256 elapsedSeconds, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /**
     * @notice Fix the parameters for a pool that does not exist yet.
     * @dev Callable by anyone, exactly once per pool id, and only before the pool is initialized. See
     * {PoolConfigurable} for why that is the right trust model.
     */
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.halfLife == 0) revert InvalidHalfLife();
        FeeMath.requireValid(cfg.baseFee);
        if (uint256(cfg.baseFee) + cfg.maxSurcharge > 1_000_000) revert SurchargeTooLarge();

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.baseFee, cfg.maxSurcharge, cfg.halfLife);
    }

    /// @notice The fee this pool would charge a swap landing right now, without changing any state.
    function quoteFee(PoolId id) public view returns (uint24) {
        Config memory cfg = configOf[id];
        uint256 elapsed = block.timestamp - lastTradeAt[id];
        return FeeMath.addClamped(cfg.baseFee, FeeMath.saturating(cfg.maxSurcharge, elapsed, cfg.halfLife));
    }

    /// @dev Requires a configuration, and starts the staleness clock at initialization.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        if (configOf[id].halfLife == 0) revert PoolNotConfigured();
        lastTradeAt[id] = uint64(block.timestamp);
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /// @dev Prices the swap and restarts the staleness clock.
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];

        uint256 elapsed = block.timestamp - lastTradeAt[id];
        lastTradeAt[id] = uint64(block.timestamp);

        uint24 fee = FeeMath.addClamped(cfg.baseFee, FeeMath.saturating(cfg.maxSurcharge, elapsed, cfg.halfLife));
        emit StalenessPriced(id, elapsed, fee);
        return fee;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "ArbTaxDecay";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "arb-tax-decay.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "mev";
        tags[1] = "lvr";
        tags[2] = "dynamic-fee";
        tags[3] = "oracle-free";
    }
}
