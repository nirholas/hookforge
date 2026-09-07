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
 * @title PriorityFeeTaxHook
 * @notice Charges a swap in proportion to what it paid the block producer to get where it is in the block.
 *
 * @dev Position in a block is worth something only to flow that is racing: an arbitrageur closing a gap against a
 * centralized venue, a liquidator, a sandwicher. A person swapping a hundred dollars of one token for another does not
 * care whether they land at index 3 or index 30, and does not bid for it. So the priority fee a transaction attaches
 * is a revealed measure of how much the trade is worth to the trader beyond the trade itself, and that surplus is
 * value the pool's liquidity providers are the counterparty to.
 *
 * The hook reads `tx.gasprice - block.basefee`, the priority fee per unit of gas actually paid, and adds a surcharge
 * along a saturating curve:
 *
 *   surcharge(priority) = maxSurcharge * priority / (priority + halfPriority)
 *
 * At `priority == halfPriority` the swap pays half the cap. The surcharge is an LP fee, so it goes to in-range
 * liquidity; the hook takes nothing and holds nothing.
 *
 * The trader cannot dodge it by bidding low, because bidding low is exactly the concession the hook is asking for: a
 * searcher who drops their priority fee to avoid the surcharge loses the race that made the trade profitable. That is
 * the point. The hook prices the option to be early rather than trying to detect who is early.
 *
 * Prior art: fee mechanisms keyed on realized volatility, on price movement and on swap size are all well covered. The
 * idea that priority fees reveal flow toxicity is discussed in the ordering-fee literature and in Uniswap's own
 * research on priority-ordering auctions, but the surcharge itself has been implemented at the sequencer or the router,
 * never inside the pool where the liquidity providers who bear the cost can be paid directly.
 *
 * Chain support, stated plainly. This works where there is a real priority-fee market: Ethereum, Base, Unichain,
 * Optimism, Blast and other OP-stack chains. On Arbitrum One transactions are ordered first-come-first-served and the
 * priority fee is normally zero, so on that chain the hook charges `baseFee` and nothing more. It is safe there, it is
 * simply inert, and a pool on Arbitrum should use {ArbTaxDecayHook} instead.
 *
 * @custom:slug priority-fee-tax
 * @custom:family Order flow and MEV
 * @custom:prior-art Fee mechanisms keyed on realized volatility, on price movement and on swap size are all well covered. That priority fees reveal flow toxicity is discussed in the ordering-fee literature and in Uniswap research on priority-ordering auctions, but the surcharge has only ever been implemented at the sequencer or the router, never inside the pool where the liquidity providers who bear the cost can be paid directly.
 * @custom:limitation Needs a real priority-fee market. On Arbitrum One, where ordering is first-come-first-served and the priority fee is normally zero, the hook is safe but inert and a pool there should use ArbTaxDecay instead.
 * @custom:chains base,unichain,ethereum,optimism,robinhood
 */
contract PriorityFeeTaxHook is ForgeFeeHook, PoolConfigurable {
    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Fee charged to a swap that paid no priority fee, in hundredths of a bip.
        uint24 baseFee;
        /// @notice Maximum surcharge added on top of `baseFee`, in hundredths of a bip.
        uint24 maxSurcharge;
        /// @notice Priority fee, in wei per gas, at which half of `maxSurcharge` applies. Must be non-zero.
        uint128 halfPriorityWei;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @dev `halfPriorityWei` was zero, which would make every non-zero priority fee pay the full surcharge.
    error InvalidHalfPriority();

    /// @dev `baseFee + maxSurcharge` must leave room under the 100% protocol maximum.
    error SurchargeTooLarge();

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 baseFee, uint24 maxSurcharge, uint128 halfPriorityWei);

    /// @notice Emitted on every swap with the priority fee that was observed and the fee that resulted.
    event PriorityPriced(PoolId indexed id, uint256 priorityFeeWei, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.halfPriorityWei == 0) revert InvalidHalfPriority();
        FeeMath.requireValid(cfg.baseFee);
        if (uint256(cfg.baseFee) + cfg.maxSurcharge > 1_000_000) revert SurchargeTooLarge();

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.baseFee, cfg.maxSurcharge, cfg.halfPriorityWei);
    }

    /**
     * @notice The priority fee, in wei per gas, that the current transaction is paying.
     * @dev Returns 0 rather than reverting on a chain or a call context where `tx.gasprice` is below the base fee,
     * which `eth_call` with no gas price set will produce.
     */
    function currentPriorityFee() public view returns (uint256) {
        return tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
    }

    /// @notice The fee this pool would charge the current transaction, without changing any state.
    function quoteFee(PoolId id) public view returns (uint24) {
        Config memory cfg = configOf[id];
        return FeeMath.addClamped(
            cfg.baseFee, FeeMath.saturating(cfg.maxSurcharge, currentPriorityFee(), cfg.halfPriorityWei)
        );
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].halfPriorityWei == 0) revert PoolNotConfigured();
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];

        uint256 priority = currentPriorityFee();
        uint24 fee =
            FeeMath.addClamped(cfg.baseFee, FeeMath.saturating(cfg.maxSurcharge, priority, cfg.halfPriorityWei));

        emit PriorityPriced(id, priority, fee);
        return fee;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "PriorityFeeTax";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "priority-fee-tax.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "mev";
        tags[1] = "dynamic-fee";
        tags[2] = "order-flow";
        tags[3] = "oracle-free";
    }
}
