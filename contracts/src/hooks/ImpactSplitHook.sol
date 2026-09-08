// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseHookFee} from "uniswap-hooks/fee/BaseHookFee.sol";

import {ForgeMetadata} from "../base/ForgeMetadata.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title ImpactSplitHook
 * @notice Charges a swap for the price impact that lasts, and gives back the impact that does not.
 *
 * @dev Market microstructure has separated two things for forty years that every AMM still treats as one. When a
 * trade moves a price, part of that move is information, and the price stays where the trade put it. The rest is the
 * cost of demanding liquidity right now, and the price comes back. The first is called permanent impact and the
 * second temporary, and the distinction is the whole reason a market maker can quote at all: they lose to the first
 * and earn from the second.
 *
 * An AMM charges a fee on size and calls it done. Size is a bad proxy for either component. A large trade in a deep
 * pool moves nothing and pays the same rate as a small one that moves the price a long way, and a pool that raises
 * its fee with volatility charges the informed and the uninformed identically because at the moment of the swap they
 * are indistinguishable.
 *
 * They are indistinguishable at that moment. They are not indistinguishable later. This hook charges every swap for
 * the impact it causes, holds the charge, and then looks again after a settlement window: whatever share of the move
 * has survived is paid to the liquidity providers who wore it, and whatever share has decayed is returned to the
 * trader who was only ever renting liquidity. Nobody has to guess which kind of flow arrived. The price says so,
 * afterwards, for free.
 *
 * A trader who moves the price and is right pays. A trader who moves the price and is wrong is refunded and has paid
 * only the pool's ordinary fee. That is the correct answer in both cases, and it is not reachable by any rule that
 * has to decide at swap time.
 *
 * @custom:slug impact-split
 * @custom:family Fees and MEV
 * @custom:prior-art Permanent and temporary impact are standard microstructure, from Kyle's lambda through Almgren-Chriss. On-chain, dynamic-fee hooks price volatility or realised spread at the moment of the swap, and markout-based fees (including this catalogue's own MarkoutFee) grade past flow to price the next trade. Deferring an individual swap's own charge, then splitting it between the providers and that same trader according to how much of its move survived a settlement window, is the contribution here.
 * @custom:limitation A single swap's persistence is measured against whatever the price does next, including other people's flow, so per-trade it is noisy and only correct in expectation; a pool with very few trades per window will hand out refunds and charges that individually look arbitrary. The charge is escrowed in the swap's unspecified currency, so a trader collects refunds in whichever side their trades happened to leave, and an unsettled escrow earns nothing while it waits. Settlement is permissionless but not automatic, so an escrow nobody settles sits until somebody does. And the window is fixed at configuration: too short and everything looks permanent, too long and everything looks temporary.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract ImpactSplitHook is BaseHookFee, ForgeMetadata, PoolConfigurable, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Per-pool terms, fixed before the pool exists.
    struct Config {
        /// @notice The most a swap can be charged for its impact, in hundredths of a bip.
        uint24 maxImpactFee;
        /// @notice The tick move at which the impact charge reaches half its cap.
        uint32 halfPointTicks;
        /// @notice How long to wait before deciding how much of a move was permanent.
        uint32 windowSeconds;
        /// @notice Moves smaller than this are treated as noise and not charged at all.
        uint32 minTicks;
    }

    /// @notice A charge held pending the verdict of the settlement window.
    struct Escrow {
        /// @notice Who gets the refund, if the move decays.
        address payer;
        /// @notice The currency the charge was taken in.
        Currency currency;
        /// @notice How much is held.
        uint128 amount;
        /// @notice The tick just before the swap. The baseline the move is measured from.
        int24 tickBefore;
        /// @notice The tick just after. Together with the baseline, this is the move being judged.
        int24 tickAfter;
        /// @notice When the escrow may be settled.
        uint64 settleAt;
    }

    /// @notice Terms for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice Escrows on a pool, by index.
    mapping(PoolId => mapping(uint256 => Escrow)) public escrowOf;

    /// @notice How many escrows a pool has ever opened.
    mapping(PoolId => uint256) public escrowCount;

    /// @notice Refunds owed to a trader, per currency, held as claims until they withdraw.
    mapping(address => mapping(Currency => uint256)) public refundOf;

    /// @dev The tick before the swap currently running, and the pool it belongs to.
    int24 private _tickBefore;

    /// @dev Which pool `_tickBefore` describes, so a stale value can never be applied to another pool.
    PoolId private _swapPool;

    /// @dev Who the running swap's escrow belongs to.
    address private _swapPayer;

    /// @dev What the unlock callback is being asked to do.
    enum Op {
        Donate,
        Withdraw
    }

    /// @dev A charge above the protocol's ceiling, or a window or half point of zero, is not a configuration.
    error InvalidConfig();

    /// @dev The escrow does not exist, or has already been settled.
    error NoSuchEscrow();

    /// @dev The settlement window has not closed yet.
    error TooSoon(uint256 settleAt);

    /// @dev There is nothing to withdraw.
    error NothingToWithdraw();

    /// @dev Only the `PoolManager` may drive the unlock callback.
    error CallbackNotPoolManager();

    /// @notice Emitted when a swap's impact charge is escrowed.
    event Escrowed(PoolId indexed id, uint256 indexed escrow, address indexed payer, uint256 amount, int24 moved);

    /// @notice Emitted when the window closes and the charge is divided.
    event Split(PoolId indexed id, uint256 indexed escrow, uint256 toProviders, uint256 refunded, uint256 survivedBps);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Fix a pool's terms before it exists. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.maxImpactFee == 0 || cfg.maxImpactFee > MAX_HOOK_FEE / 10) revert InvalidConfig();
        if (cfg.halfPointTicks == 0 || cfg.windowSeconds == 0) revert InvalidConfig();

        _requireUninitialized(key);
        configOf[PoolId.wrap(keccak256(abi.encode(key)))] = cfg;
    }

    /**
     * @notice The charge a swap would pay for moving the price `movedTicks`, in hundredths of a bip.
     * @dev The whole fee schedule, as a function anybody can plot. A move below the pool's noise floor is free, and
     * everything above it approaches the cap without reaching it.
     */
    function impactFeeFor(PoolKey calldata key, uint256 movedTicks) public view returns (uint24) {
        Config memory cfg = configOf[key.toId()];
        if (cfg.windowSeconds == 0 || movedTicks < cfg.minTicks) return 0;
        return FeeMath.saturating(cfg.maxImpactFee, movedTicks, cfg.halfPointTicks).toUint24();
    }

    /**
     * @notice What share of an escrow's move has survived, in basis points.
     *
     * @dev Zero means the price came all the way back and the whole charge is a refund. Ten thousand means the move
     * held completely, or went further, and the whole charge belongs to the providers. Anything between splits it.
     * Measured against the tick now, whatever else has happened since, because "where did the price end up" is the
     * only definition of permanent impact that does not require knowing which trades were whose.
     */
    function survivedBps(PoolKey calldata key, uint256 escrow) public view returns (uint256) {
        PoolId id = key.toId();
        Escrow memory held = escrowOf[id][escrow];
        if (held.payer == address(0)) return 0;

        (, int24 tick,,) = poolManager.getSlot0(id);
        return _survived(held, tick);
    }

    /// @dev The surviving share of a move, given where the tick stands now.
    function _survived(Escrow memory held, int24 tickNow) private pure returns (uint256) {
        int256 moved = int256(held.tickAfter) - int256(held.tickBefore);
        if (moved == 0) return 0;

        int256 remains = int256(tickNow) - int256(held.tickBefore);
        // A price that came back past where it started, or reversed entirely, kept none of the move.
        if ((moved > 0) != (remains > 0)) return 0;

        uint256 magnitude = _abs(moved);
        uint256 kept = _abs(remains);
        // A move that carried further than the swap made it is capped: this swap is not owed the rest of the market.
        return kept >= magnitude ? BPS : (kept * BPS) / magnitude;
    }

    /// @dev Absolute value, widened first so negating the minimum cannot wrap.
    function _abs(int256 value) private pure returns (uint256) {
        return (value < 0 ? -value : value).toUint256();
    }

    /**
     * @notice Close an escrow, paying the surviving share to the providers and refunding the rest.
     * @dev Permissionless. Nobody is paid for calling it, because the money it moves is already owed to two parties
     * who both want it moved, and a bounty would only come out of theirs.
     */
    function settle(PoolKey calldata key, uint256 escrow) external {
        PoolId id = key.toId();
        Escrow memory held = escrowOf[id][escrow];
        if (held.payer == address(0)) revert NoSuchEscrow();
        // A window measured in minutes or hours cannot be meaningfully shifted by the seconds a proposer controls,
        // and settling early only makes a move look more permanent than it is, which costs the settler nothing.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < held.settleAt) revert TooSoon(held.settleAt);

        (, int24 tick,,) = poolManager.getSlot0(id);
        uint256 survived = _survived(held, tick);

        uint256 toProviders = (uint256(held.amount) * survived) / BPS;
        uint256 refunded = uint256(held.amount) - toProviders;

        delete escrowOf[id][escrow];
        if (refunded > 0) refundOf[held.payer][held.currency] += refunded;
        if (toProviders > 0) poolManager.unlock(abi.encode(Op.Donate, key, held.currency, address(0), toProviders));

        emit Split(id, escrow, toProviders, refunded, survived);
    }

    /// @notice Withdraw refunds from settled escrows, as real tokens rather than claims.
    function withdraw(PoolKey calldata key) external {
        uint256 amount0 = refundOf[msg.sender][key.currency0];
        uint256 amount1 = refundOf[msg.sender][key.currency1];
        if (amount0 == 0 && amount1 == 0) revert NothingToWithdraw();

        refundOf[msg.sender][key.currency0] = 0;
        refundOf[msg.sender][key.currency1] = 0;
        poolManager.unlock(abi.encode(Op.Withdraw, key, Currency.wrap(address(0)), msg.sender, (amount1 << 128) | amount0));
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Two operations share one callback because a hook only gets one. The discriminator is explicit rather than
     * inferred from the payload's shape, which would break the first time two shapes coincided.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();
        (Op op, PoolKey memory key, Currency currency, address to, uint256 packed) =
            abi.decode(data, (Op, PoolKey, Currency, address, uint256));

        if (op == Op.Donate) {
            // Donating burns the claim the charge is already held as, so no token ever moves.
            bool isZero = Currency.unwrap(currency) == Currency.unwrap(key.currency0);
            poolManager.donate(key, isZero ? packed : 0, isZero ? 0 : packed, "");
            poolManager.burn(address(this), currency.toId(), packed);
            return "";
        }

        uint256 amount0 = packed & type(uint128).max;
        uint256 amount1 = packed >> 128;
        if (amount0 > 0) {
            poolManager.burn(address(this), key.currency0.toId(), amount0);
            poolManager.take(key.currency0, to, amount0);
        }
        if (amount1 > 0) {
            poolManager.burn(address(this), key.currency1.toId(), amount1);
            poolManager.take(key.currency1, to, amount1);
        }
        return "";
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].windowSeconds == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Records where the price stood before the swap, and who the escrow belongs to.
     *
     * A swap reaches the hook from a router, so the payer is named in `hookData` rather than read from the caller.
     * No signature is needed: naming somebody else gives away your own refund, which is the only thing a forged
     * attribution can achieve.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tick,,) = poolManager.getSlot0(id);
        _swapPool = id;
        _tickBefore = tick;
        _swapPayer = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev The charge for this swap's impact, scaled by how far it moved the price.
    function _getHookFee(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        PoolId id = key.toId();
        if (PoolId.unwrap(_swapPool) != PoolId.unwrap(id)) return 0;

        (, int24 tick,,) = poolManager.getSlot0(id);
        return impactFeeFor(key, _abs(int256(tick) - int256(_tickBefore)));
    }

    /**
     * @dev Escrows whatever the charge came to, rather than keeping it.
     *
     * The amount is measured as the change in the hook's own claims rather than recomputed from the fee, because the
     * base contract already did that arithmetic and its rounding once, and doing it twice invites the two to differ.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (uint256 before0, uint256 before1) = _held(key);
        (bytes4 selector, int128 hookDelta) = super._afterSwap(sender, key, params, delta, hookData);
        _escrow(key, before0, before1);
        return (selector, hookDelta);
    }

    /// @dev What the hook holds of each of the pool's currencies, as ERC-6909 claims.
    function _held(PoolKey calldata key) private view returns (uint256 held0, uint256 held1) {
        held0 = poolManager.balanceOf(address(this), key.currency0.toId());
        held1 = poolManager.balanceOf(address(this), key.currency1.toId());
    }

    /// @dev Opens the escrow for the charge the swap just paid, measured against what the hook held before it.
    function _escrow(PoolKey calldata key, uint256 before0, uint256 before1) private {
        PoolId id = key.toId();
        (uint256 after0, uint256 after1) = _held(key);

        uint256 amount = (after0 - before0) + (after1 - before1);
        if (amount == 0) return;

        Currency currency = after0 > before0 ? key.currency0 : key.currency1;
        (, int24 tick,,) = poolManager.getSlot0(id);

        uint256 index = escrowCount[id]++;
        escrowOf[id][index] = Escrow({
            payer: _swapPayer,
            currency: currency,
            amount: amount.toUint128(),
            tickBefore: _tickBefore,
            tickAfter: tick,
            settleAt: uint64(block.timestamp) + configOf[id].windowSeconds
        });

        emit Escrowed(id, index, _swapPayer, amount, tick - _tickBefore);
    }

    /**
     * @inheritdoc BaseHookFee
     * @dev Nothing to do. Every charge is escrowed as it is taken and leaves through {settle}, which is the same
     * claims divided between the two parties entitled to them.
     */
    function handleHookFees(Currency[] memory) public pure override {}

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
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
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "ImpactSplit";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "impact-split.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "fees";
        tags[1] = "price-impact";
        tags[2] = "microstructure";
        tags[3] = "rebate";
        tags[4] = "no-admin";
    }
}
