// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/**
 * @title OracleBandHook
 * @notice Refuses to let a pool settle at a price the wider market does not recognise.
 *
 * @dev A thin pool can be walked anywhere. Buy through the last tick of liquidity and the pool will quote you a price
 * no other venue would, and whatever reads that pool afterwards, a lending market, a vault, another pool's oracle,
 * inherits the number. The pool is not wrong: it faithfully reports what it was paid. It is simply alone.
 *
 * This hook gives the pool a second opinion. Before and after every swap it compares the pool price against a
 * reference from an {IPriceOracle} and rejects the swap if the result lands outside a band around it:
 *
 *   deviation = |poolPrice / referencePrice - 1|, rejected when deviation > maxDeviationBps
 *
 * The check runs on both sides of the swap, and the pair is what makes it hard to defeat. The `beforeSwap` check
 * refuses to trade from a price that is already outside the band, so a pool pushed out of line in one transaction
 * cannot be traded against in the next. The `afterSwap` check refuses to leave the pool outside the band, which is
 * what stops the walk in the first place. Neither check can be satisfied by splitting a large swap into small ones,
 * because the constraint is on the resulting price rather than on the size of the trade.
 *
 * Prices are compared in `sqrtPriceX96`, squared back through `FullMath` so the comparison is on the actual price
 * ratio and not on an approximation of it that drifts as the deviation grows.
 *
 * Liquidity operations are untouched. A provider can always withdraw, including while the band is refusing swaps,
 * which is the property that makes it safe to sit behind one.
 *
 * The obvious objection: this makes the pool depend on an oracle, and oracles fail. So the hook treats failure as
 * refusal rather than as permission. A feed older than `maxStaleness` halts swapping instead of waving it through,
 * and a feed that reverts propagates rather than being caught. A pool that would rather trade blind than not trade
 * should not use this hook, and the fee-based hooks in this catalogue are the oracle-free alternative.
 *
 * @custom:slug oracle-band
 * @custom:family Risk
 * @custom:prior-art Oracle-deviation checks exist inside individual protocols, and Detox uses Pyth to detect MEV and
 * redirect it. Both act after the fact, on a pool that has already printed the price. Enforcing the band as a
 * precondition on both sides of the swap, so the out-of-band price is never written at all, is what is new here.
 * @custom:limitation The pool inherits the oracle's liveness. If the feed stops, swapping stops, and on a chain where
 * the feed updates on a deviation threshold rather than a heartbeat, a quiet market can look stale. Set
 * maxStaleness against the feed's actual publication cadence, not against how fresh you would like it to be.
 * @custom:chains base,arbitrum,unichain,ethereum,optimism,polygon,bnb
 */
contract OracleBandHook is ForgeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice The reference price source.
        IPriceOracle oracle;
        /// @notice How far the pool may sit from the reference, in basis points. Must be non-zero.
        uint32 maxDeviationBps;
        /// @notice How old the reference may be before swapping halts, in seconds. Must be non-zero.
        uint32 maxStaleness;
    }

    /// @dev One in `1e18`, the fixed point the deviation is computed in.
    uint256 private constant ONE = 1e18;

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @dev `maxDeviationBps` or `maxStaleness` was zero, or no oracle was given.
    error InvalidConfig();

    /// @dev The pool price is outside the band around the reference.
    error OutsideBand(uint256 deviationBps, uint32 maxDeviationBps);

    /// @dev The reference price is older than the pool tolerates, so the pool declines to trade.
    error ReferenceStale(uint256 updatedAt, uint32 maxStaleness);

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, address oracle, uint32 maxDeviationBps, uint32 maxStaleness);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (address(cfg.oracle) == address(0) || cfg.maxDeviationBps == 0 || cfg.maxStaleness == 0) {
            revert InvalidConfig();
        }

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, address(cfg.oracle), cfg.maxDeviationBps, cfg.maxStaleness);
    }

    /**
     * @notice How far the pool currently sits from its reference, in basis points, and whether that is inside the band.
     * @dev Reverts if the reference is stale, for the same reason a swap would: a stale answer is not a small
     * deviation, it is no answer at all.
     */
    function deviation(PoolId id) public view returns (uint256 deviationBps, bool withinBand) {
        Config memory cfg = configOf[id];
        (uint160 poolPrice,,,) = poolManager.getSlot0(id);
        deviationBps = _deviationBps(cfg, poolPrice);
        withinBand = deviationBps <= cfg.maxDeviationBps;
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

    /// @dev Requires a configuration, and requires the pool to open inside its own band.
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        if (address(cfg.oracle) == address(0)) revert PoolNotConfigured();

        _requireWithinBand(cfg, sqrtPriceX96);
        return this.afterInitialize.selector;
    }

    /// @dev Refuses to trade from a price that is already outside the band.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (uint160 poolPrice,,,) = poolManager.getSlot0(id);
        _requireWithinBand(configOf[id], poolPrice);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Refuses to leave the pool outside the band, which is what stops a walk rather than merely noticing it.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (uint160 poolPrice,,,) = poolManager.getSlot0(id);
        _requireWithinBand(configOf[id], poolPrice);

        return (this.afterSwap.selector, 0);
    }

    /// @dev Reverts unless `poolPrice` sits inside the configured band around a sufficiently fresh reference.
    function _requireWithinBand(Config memory cfg, uint160 poolPrice) private view {
        uint256 deviationBps = _deviationBps(cfg, poolPrice);
        if (deviationBps > cfg.maxDeviationBps) revert OutsideBand(deviationBps, cfg.maxDeviationBps);
    }

    /**
     * @dev `|poolPrice^2 / referencePrice^2 - 1|` in basis points.
     *
     * Both inputs are square roots of the price, so the ratio is squared before the deviation is taken. Doing it the
     * other way, comparing the square roots directly, understates a real deviation by roughly half and gets worse the
     * further the pool has moved, which is precisely when the answer matters.
     */
    function _deviationBps(Config memory cfg, uint160 poolPrice) private view returns (uint256) {
        (uint160 referencePrice, uint256 updatedAt) = cfg.oracle.sqrtPriceX96();
        // Safe against timestamp drift: the tolerance is a feed's publication cadence, tens of seconds at least, so
        // the seconds a proposer can shift `block.timestamp` by cannot turn a fresh answer into a stale one.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > updatedAt + cfg.maxStaleness) revert ReferenceStale(updatedAt, cfg.maxStaleness);

        uint256 sqrtRatio = FullMath.mulDiv(poolPrice, ONE, referencePrice);
        uint256 priceRatio = FullMath.mulDiv(sqrtRatio, sqrtRatio, ONE);
        uint256 gap = priceRatio > ONE ? priceRatio - ONE : ONE - priceRatio;

        return FullMath.mulDiv(gap, 10_000, ONE);
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "OracleBand";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "oracle-band.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "risk";
        tags[1] = "oracle";
        tags[2] = "manipulation-resistance";
        tags[3] = "no-admin";
    }
}
