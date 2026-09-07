// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title DepegShieldHook
 * @notice Makes leaving a peg expensive and returning to it cheap, in proportion to how far the pool has already
 * strayed.
 *
 * @dev A pegged pool fails in a specific way. Something spooks the market, the first sellers cross, the price slips,
 * and the slip is itself the signal that brings the next sellers. Liquidity providers are filled the whole way down at
 * a fee that was set for a pool sitting at par. By the time anyone reacts, the pool is one-sided and the providers own
 * the asset that broke.
 *
 * This hook makes the fee a function of two things: how far the pool is from the peg, and which way the swap pushes
 * it. A swap that widens the gap pays `baseFee` plus a surcharge that grows with the existing deviation. A swap that
 * closes the gap pays less than `baseFee`, down to a floor, with the discount growing the same way. The result is a
 * spread that opens as the pool strays and pays anyone willing to push it back.
 *
 *   widening:  fee = baseFee + maxSurcharge * deviation / (deviation + halfDeviation)
 *   restoring: fee = baseFee - (baseFee - minFee) * deviation / (deviation + halfDeviation)
 *
 * Both are LP fees, so the surcharge is paid to liquidity and the discount is given up by liquidity. That is the right
 * trade for a provider in a pegged pool: paying for the flow that repairs the pool is cheaper than being filled on the
 * way out.
 *
 * The peg is a tick, not an oracle. `pegTick = 0` is a one-to-one pool; a pair whose par is not one-to-one sets the
 * tick that corresponds to par. Since it is fixed at initialization, there is nothing to manipulate and no feed to go
 * stale, and a pool whose peg genuinely re-bases has to be re-created, which for a pegged pair is the honest outcome.
 *
 * Deviation is measured in ticks. One tick is one basis point to within rounding, so `halfDeviationTicks = 50` means
 * half the surcharge applies once the pool is fifty basis points off par.
 *
 * Prior art: stable-swap curves flatten the price impact near par, and dynamic-fee hooks keyed on volatility exist.
 * Neither is directional. A curve treats a swap toward the peg and a swap away from it identically, and a volatility
 * fee charges the repairing flow exactly as much as the flow that broke the pool. Charging asymmetrically by direction
 * of travel is what is new here.
 */
contract DepegShieldHook is ForgeFeeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice The tick that represents par. Zero for a one-to-one pool.
        int24 pegTick;
        /// @notice Fee charged exactly at the peg, in hundredths of a bip.
        uint24 baseFee;
        /// @notice Floor the fee decays to for peg-restoring swaps. Must not exceed `baseFee`.
        uint24 minFee;
        /// @notice Maximum surcharge added for peg-widening swaps, in hundredths of a bip.
        uint24 maxSurcharge;
        /// @notice Ticks of deviation at which half the surcharge or discount applies. Must be non-zero.
        uint24 halfDeviationTicks;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @dev `halfDeviationTicks` was zero, or `minFee` exceeded `baseFee`.
    error InvalidConfig();

    /// @dev `baseFee + maxSurcharge` must leave room under the 100% protocol maximum.
    error SurchargeTooLarge();

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, int24 pegTick, uint24 baseFee, uint24 minFee, uint24 maxSurcharge);

    /// @notice Emitted on every swap with the deviation observed, the direction of travel and the fee charged.
    event DeviationPriced(PoolId indexed id, uint256 deviationTicks, bool restoring, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.halfDeviationTicks == 0 || cfg.minFee > cfg.baseFee) revert InvalidConfig();
        FeeMath.requireValid(cfg.baseFee);
        if (uint256(cfg.baseFee) + cfg.maxSurcharge > 1_000_000) revert SurchargeTooLarge();

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.pegTick, cfg.baseFee, cfg.minFee, cfg.maxSurcharge);
    }

    /**
     * @notice The fee a swap in direction `zeroForOne` would pay right now.
     * @param zeroForOne Direction of the hypothetical swap. Selling currency0 pushes the tick down.
     */
    function quoteFee(PoolId id, bool zeroForOne) public view returns (uint24 fee, uint256 deviationTicks, bool restoring) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        return _price(configOf[id], tick, zeroForOne);
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].halfDeviationTicks == 0) revert PoolNotConfigured();
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tick,,) = poolManager.getSlot0(id);

        (uint24 fee, uint256 deviation, bool restoring) = _price(configOf[id], tick, params.zeroForOne);
        emit DeviationPriced(id, deviation, restoring, fee);
        return fee;
    }

    /**
     * @notice The fee a pool with these parameters would charge at `tick` for a swap in direction `zeroForOne`.
     * @dev Pure, so quoters, routers and the SDK can price a swap without touching pool state.
     */
    function previewFee(Config memory cfg, int24 tick, bool zeroForOne)
        public
        pure
        returns (uint24 fee, uint256 deviationTicks, bool restoring)
    {
        return _price(cfg, tick, zeroForOne);
    }

    /**
     * @dev The pricing rule, pure so it can be reasoned about and fuzzed on its own.
     * @param tick The pool's current tick.
     * @param zeroForOne Direction of the swap. Selling currency0 moves the tick down.
     */
    function _price(Config memory cfg, int24 tick, bool zeroForOne)
        internal
        pure
        returns (uint24 fee, uint256 deviationTicks, bool restoring)
    {
        int24 delta = tick - cfg.pegTick;
        deviationTicks = uint256(int256(delta >= 0 ? delta : -delta));

        // Above the peg the pool is rich in currency1, so selling currency0 into it (zeroForOne) walks the tick back
        // down toward par. Below the peg the reverse holds. Exactly at the peg the deviation is zero and both branches
        // return `baseFee`, so the direction does not matter.
        restoring = delta > 0 ? zeroForOne : (delta < 0 ? !zeroForOne : true);

        if (restoring) {
            uint256 discount =
                FeeMath.saturating(uint256(cfg.baseFee) - cfg.minFee, deviationTicks, cfg.halfDeviationTicks);
            fee = uint24(uint256(cfg.baseFee) - discount);
        } else {
            fee = FeeMath.addClamped(
                cfg.baseFee, FeeMath.saturating(cfg.maxSurcharge, deviationTicks, cfg.halfDeviationTicks)
            );
        }
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "DepegShield";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "depeg-shield.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "risk";
        tags[1] = "stablecoin";
        tags[2] = "dynamic-fee";
        tags[3] = "oracle-free";
    }
}
