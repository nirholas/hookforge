// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title BlockReversalHook
 * @notice Charges the swap that unwinds a block's own price move, which is the only leg of a sandwich that can be
 * identified without knowing who anybody is.
 *
 * @dev Anti-sandwich designs almost all try to identify the attacker: track an address, require a bond, tax a trader
 * who reverses direction. Every one of them is defeated by a second EOA, which costs a bot nothing. Identity is the
 * wrong thing to look at, because a sandwich is not a property of who is trading. It is a property of the price path.
 *
 * A sandwich has a shape: within one block, the price moves away from where the block opened and then comes back. The
 * profitable leg is always the one that comes back, because that is where the position is closed. This hook never
 * asks who is trading. It records where the price stood when the block opened, watches how far it has travelled since,
 * and prices any swap that moves it back toward the opening more expensively the more of that move it is unwinding.
 *
 * The victim is not charged: their swap is the one that moves the price away. Nor is the attacker's opening leg. Only
 * the close pays, which is the leg that has something to pay with.
 *
 * The same charge lands on an honest trader who happens to trade against the block's direction, and that is not a
 * flaw to apologise for. Such a trader is buying at a price that an earlier trade in the same block improved for
 * them, at the expense of the liquidity providers who supplied it. Returning part of that improvement to those
 * providers is the correct answer whether the trader meant to sandwich anybody or not. The fee is an LP fee, so that
 * is exactly where it goes.
 *
 * Nothing here needs an oracle, an auction, a keeper, a bond, a private mempool, or a way to tell one address from
 * another. It reads the pool's own tick against where the block opened, and that is all.
 *
 * @custom:slug block-reversal
 * @custom:family Order flow and MEV
 * @custom:prior-art Sandwich-resistant AMM designs reorder or batch within a block. Encrypted mempools (Shutter, SUAVE) hide the order. Auction-based capture (am-AMM, MEV-Share, Diamond) sells or reclaims the backrun. Volatility-indexed dynamic fees raise the fee for everybody when the pool is moving. Pricing an individual swap by how much of the current block's own price move it is unwinding, so the closing leg pays and the victim does not, with no identity and no auction, is the contribution here.
 * @custom:limitation An honest trader who trades against the block's direction pays the surcharge too. That is deliberate and it is the real cost: the mechanism cannot distinguish a sandwich close from an ordinary trade in the same direction, because at the level it observes them they are the same event. It also does nothing about a sandwich split across two blocks, which is a different and much riskier attack for the attacker to run. And a pool with a large `thresholdTicks` is protected only against sandwiches big enough to cross it, while a small one charges ordinary two-way flow more often; that trade is the pool's to make.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract BlockReversalHook is ForgeFeeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @notice Per-pool terms, fixed before the pool exists.
    struct Config {
        /// @notice What a swap costs when it is not unwinding anything, in hundredths of a bip.
        uint24 baseFee;
        /// @notice The most that can be added on top of the base fee for unwinding.
        uint24 maxSurcharge;
        /// @notice How far the price must have moved this block before an unwind is charged at all.
        int24 thresholdTicks;
        /// @notice The move, past the threshold, at which the surcharge reaches half its cap.
        int24 halfPointTicks;
    }

    /// @notice What a pool's price has done so far in the current block.
    struct BlockState {
        /// @notice The block this state describes.
        uint64 number;
        /// @notice Where the tick stood when the block opened.
        int24 openedAt;
        /// @notice The furthest the tick has been from the opening, signed, so far this block.
        int24 extreme;
    }

    /// @notice Terms for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The current block's price path, per pool.
    mapping(PoolId => BlockState) public blockStateOf;

    /// @dev A surcharge cannot push the total past the protocol's own ceiling on an LP fee.
    error FeeTooLarge();

    /// @dev A threshold or half point of zero would make the surcharge fire on any move at all.
    error InvalidThreshold();

    /**
     * @notice Emitted for every swap, with the fee it was charged and the block move that produced it.
     * @dev An override hook never writes its fee to the pool, so this event is the only durable record of what a swap
     * actually paid. Emitting it on every swap rather than only on a surcharge means an indexer sees the whole
     * distribution instead of just its tail.
     * @param zeroForOne Direction of the swap.
     * @param movedTicks How far the price had travelled from the block's opening when this swap was priced.
     * @param fee The total fee applied, in hundredths of a bip.
     */
    event Priced(PoolId indexed id, bool zeroForOne, int24 movedTicks, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix a pool's terms before it exists. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (uint256(cfg.baseFee) + cfg.maxSurcharge > 1_000_000) revert FeeTooLarge();
        if (cfg.thresholdTicks <= 0 || cfg.halfPointTicks <= 0) revert InvalidThreshold();

        _requireUninitialized(key);
        configOf[PoolId.wrap(keccak256(abi.encode(key)))] = cfg;
    }

    /**
     * @notice The fee this pool would charge a swap in `zeroForOne` right now.
     * @dev The same computation the swap itself uses, exposed so a router can quote it and a trader can see why the
     * two directions are priced differently at this moment.
     */
    function quoteFee(PoolKey calldata key, bool zeroForOne) public view returns (uint24) {
        PoolId id = key.toId();
        Config memory cfg = configOf[id];
        if (cfg.baseFee == 0 && cfg.maxSurcharge == 0) return 0;

        (, int24 tick,,) = poolManager.getSlot0(id);
        BlockState memory state = blockStateOf[id];
        if (state.number != uint64(block.number)) return cfg.baseFee;

        return cfg.baseFee + _surcharge(cfg, state, tick, zeroForOne);
    }

    /**
     * @dev The surcharge for a swap in `zeroForOne`, given where the block opened and where the tick stands.
     *
     * `moved` is how far the price has travelled from the opening, signed. A swap unwinds that move when it pushes
     * the tick back toward the opening: selling currency0 pushes the tick down, so it unwinds a move that went up.
     * Everything past the threshold is what the surcharge is scaled by, so a pool only charges for a move large
     * enough to have been worth attacking.
     */
    function _surcharge(Config memory cfg, BlockState memory state, int24 tick, bool zeroForOne)
        private
        pure
        returns (uint24)
    {
        int24 moved = tick - state.openedAt;
        // The block's furthest excursion is what matters, not where it happens to sit: a sandwich that has already
        // been partly unwound is still unwinding the same move.
        if (_abs(state.extreme) > _abs(moved) && _sameSign(state.extreme, moved)) moved = state.extreme;

        bool unwinding = moved > 0 ? zeroForOne : (moved < 0 && !zeroForOne);
        if (!unwinding) return 0;

        uint256 distance = _abs(moved);
        uint256 threshold = _abs(cfg.thresholdTicks);
        if (distance <= threshold) return 0;

        uint256 beyond = distance - threshold;
        uint256 surcharge = FeeMath.saturating(cfg.maxSurcharge, beyond, _abs(cfg.halfPointTicks));
        // Bounded by `maxSurcharge`, which the constructor already held below the protocol ceiling.
        return surcharge.toUint24();
    }

    /// @dev Absolute value of a tick, as an unsigned distance. Widened first, so negating the minimum cannot wrap.
    function _abs(int24 value) private pure returns (uint256) {
        int256 wide = value;
        return (wide < 0 ? -wide : wide).toUint256();
    }

    /// @dev Whether two signed ticks point the same way. Zero points nowhere, and matches nothing.
    function _sameSign(int24 a, int24 b) private pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    /// @dev Requires a configuration, and opens the first block's state where the pool starts.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        if (configOf[id].thresholdTicks == 0) revert PoolNotConfigured();

        blockStateOf[id] = BlockState({number: uint64(block.number), openedAt: tick, extreme: 0});
        return this.afterInitialize.selector;
    }

    /**
     * @dev Prices the swap, and records what the block has done so far.
     *
     * The tick read here is the one the previous swap left behind, which is exactly the block's move up to this
     * point. Reading it in `beforeSwap` rather than tracking it in `afterSwap` means one storage slot and one read
     * instead of two writes per swap, and it is the same number.
     */
    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        (, int24 tick,,) = poolManager.getSlot0(id);

        BlockState memory state = blockStateOf[id];
        if (state.number != uint64(block.number)) {
            // A new block opens where the last one closed, and has travelled nowhere yet.
            state = BlockState({number: uint64(block.number), openedAt: tick, extreme: 0});
        } else {
            int24 moved = tick - state.openedAt;
            if (_abs(moved) > _abs(state.extreme)) state.extreme = moved;
        }
        blockStateOf[id] = state;

        uint24 fee = cfg.baseFee + _surcharge(cfg, state, tick, params.zeroForOne);
        emit Priced(id, params.zeroForOne, state.extreme, fee);
        return fee;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "BlockReversal";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "block-reversal.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "mev";
        tags[1] = "anti-sandwich";
        tags[2] = "dynamic-fee";
        tags[3] = "oracle-free";
        tags[4] = "no-admin";
    }
}
