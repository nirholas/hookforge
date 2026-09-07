// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title ExpirySettleHook
 * @notice Gives a pool a maturity, and makes moving its price monotonically more expensive as that maturity
 * approaches, so the settlement price is dearest to manipulate exactly when manipulating it would pay most.
 *
 * @dev Any dated instrument that settles against a market price has the same problem at the end of its life. The
 * payoff of pushing the price around is largest in the final minutes, because there is no time left for anybody to
 * push it back, and the cost of pushing it is unchanged from any other moment. Traditional markets answer this with
 * a settlement window: the official price is an average over the closing period rather than a single print, which
 * makes a manipulator pay for the whole window instead of one instant.
 *
 * A pool cannot average its own price without an oracle, but it can do something a traditional venue cannot: change
 * what moving the price costs. As maturity approaches, this hook ramps the fee from `baseFee` up to `settlementFee`
 * across the last `windowSeconds`, on a curve that is quadratic rather than linear so the final moments are much more
 * expensive than the early part of the window:
 *
 *   fee(t) = baseFee + (settlementFee - baseFee) * elapsed^2 / windowSeconds^2
 *
 * A manipulator who wants to move the settlement print has to choose between acting early, where the fee is low but
 * there is time for somebody to trade against them, and acting late, where nobody can respond but every basis point
 * of the move costs several times more. The fee is paid to the liquidity that has to absorb the move, which is the
 * party bearing the cost.
 *
 * At maturity the pool stops trading. Swaps revert, so the price cannot move again, and `settlementPrice` is simply
 * the pool's final tick. Liquidity may always be removed, including after maturity, because a matured pool that
 * cannot be exited is a trap rather than an instrument. Adding liquidity after maturity reverts: there is nothing
 * left to provide liquidity for, and permitting it would only let somebody strand funds.
 *
 * The hook holds nothing, takes nothing for itself, and has no privileged role. The maturity is fixed before the pool
 * exists and cannot be moved by anyone, which is the property that makes the instrument datable at all.
 *
 * @custom:slug expiry-settle
 * @custom:family Time
 * @custom:prior-art Dated AMMs exist (YieldSpace and Pendle-style curves converge to par at maturity), and hooks that halt trading on a schedule exist. Settlement-window design is standard in traditional derivatives. Making the *cost* of moving an AMM's price rise on a convex curve into its own settlement, as the on-chain substitute for a time-averaged settlement price, is the contribution here.
 * @custom:limitation It raises the cost of manipulation, it does not prevent it. A manipulator whose payoff exceeds the ramped fee will still pay it, and the right response is to size `settlementFee` against the notional settling on the price rather than against ordinary trading. The hook also cannot know what the pool settles for, so if nothing actually references `settlementPrice`, the ramp is pure cost with no benefit.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract ExpirySettleHook is ForgeFeeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice When the pool stops trading, as a unix timestamp.
        uint64 maturity;
        /// @notice How long before maturity the fee starts ramping, in seconds. Must be non-zero.
        uint32 windowSeconds;
        /// @notice Fee outside the settlement window, in hundredths of a bip.
        uint24 baseFee;
        /// @notice Fee in the final instant before maturity, in hundredths of a bip.
        uint24 settlementFee;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @dev `windowSeconds` was zero, which would turn the ramp into a cliff at maturity.
    error InvalidWindow();

    /// @dev The maturity must be far enough ahead to contain the whole settlement window.
    error MaturityTooSoon();

    /// @dev `settlementFee` must be at least `baseFee`; a ramp that gets cheaper into settlement inverts the point.
    error SettlementFeeBelowBase();

    /// @dev The pool has matured. Its price is final and it no longer trades.
    error Matured(uint64 maturity);

    /// @notice Emitted once per pool, when its maturity is fixed.
    event PoolConfigured(PoolId indexed id, uint64 maturity, uint32 windowSeconds, uint24 baseFee, uint24 settlementFee);

    /// @notice Emitted on every swap inside the settlement window, with the fee the ramp produced.
    event SettlementRamp(PoolId indexed id, uint256 secondsToMaturity, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix the maturity and ramp for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.windowSeconds == 0) revert InvalidWindow();
        // Both bounds matter: a maturity in the past is meaningless, and one inside the window would start the pool
        // already ramping, which is a configuration mistake rather than a design choice.
        // forge-lint: disable-next-line(block-timestamp)
        if (cfg.maturity <= block.timestamp + cfg.windowSeconds) revert MaturityTooSoon();
        if (cfg.settlementFee < cfg.baseFee) revert SettlementFeeBelowBase();
        FeeMath.requireValid(cfg.settlementFee);

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.maturity, cfg.windowSeconds, cfg.baseFee, cfg.settlementFee);
    }

    /// @notice Whether the pool has reached its maturity and stopped trading.
    function hasMatured(PoolId id) public view returns (bool) {
        uint64 maturity = configOf[id].maturity;
        // A maturity is set days or weeks ahead; proposer drift cannot move it by anything that matters.
        // forge-lint: disable-next-line(block-timestamp)
        return maturity != 0 && block.timestamp >= maturity;
    }

    /// @notice Seconds until the pool matures, or zero once it has.
    function timeToMaturity(PoolId id) public view returns (uint256) {
        uint64 maturity = configOf[id].maturity;
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp >= maturity ? 0 : maturity - block.timestamp;
    }

    /**
     * @notice The fee a swap would pay at `timestamp`.
     * @dev Pure in everything but the configuration, so an off-chain quoter can reproduce the whole ramp exactly.
     */
    function feeAt(PoolId id, uint256 timestamp) public view returns (uint24) {
        Config memory cfg = configOf[id];
        if (timestamp >= cfg.maturity) return cfg.settlementFee;

        uint256 remaining = cfg.maturity - timestamp;
        if (remaining >= cfg.windowSeconds) return cfg.baseFee;

        // Quadratic in how far into the window we are, so the last moments cost several times the first ones.
        uint256 elapsed = cfg.windowSeconds - remaining;
        uint256 spread = uint256(cfg.settlementFee) - cfg.baseFee;
        uint256 window = cfg.windowSeconds;
        return FeeMath.addClamped(cfg.baseFee, (spread * elapsed * elapsed) / (window * window));
    }

    /// @notice The fee a swap would pay right now.
    function quoteFee(PoolId id) external view returns (uint24) {
        return feeAt(id, block.timestamp);
    }

    /**
     * @notice The pool's final price, once it has matured.
     * @dev No recording is needed: swaps revert after maturity, so the pool's own tick stops moving and is itself the
     * settlement price. Reverts before maturity, because a settlement price that is still moving is not one.
     */
    function settlementPrice(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick) {
        if (!hasMatured(id)) revert NotYetMatured(configOf[id].maturity);
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
    }

    /// @dev The pool has not matured, so it has no settlement price yet.
    error NotYetMatured(uint64 maturity);

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].maturity == 0) revert PoolNotConfigured();
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /// @dev Prices the swap off the ramp, and refuses it once the pool has matured.
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= cfg.maturity) revert Matured(cfg.maturity);

        uint24 fee = feeAt(id, block.timestamp);
        uint256 remaining = cfg.maturity - block.timestamp;
        if (remaining < cfg.windowSeconds) emit SettlementRamp(id, remaining, fee);
        return fee;
    }

    /**
     * @dev Refuses new liquidity once the pool has matured.
     *
     * Removal is deliberately never blocked, here or anywhere else in this contract. A matured pool that cannot be
     * exited is a trap, and the whole point of settling at a known price is that everyone can then leave against it.
     */
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        if (hasMatured(id)) revert Matured(configOf[id].maturity);
        return this.beforeAddLiquidity.selector;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
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
        return "ExpirySettle";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "expiry-settle.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "expiry";
        tags[1] = "settlement";
        tags[2] = "dynamic-fee";
        tags[3] = "derivatives";
        tags[4] = "oracle-free";
    }
}
