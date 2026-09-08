// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeHook} from "../base/ForgeHook.sol";

/**
 * @title FungibleRangeHook
 * @notice A concentrated position with fungible shares, whose band widens every time it is forced to move.
 *
 * @dev Fungible wrappers around concentrated liquidity are old: Gamma, Arrakis and the Alpha Vaults have run them for
 * years. They all share a shape, and a defect that comes with it. The shape is a vault that sits outside the pool,
 * holds a position, and is moved by a keeper. The defect is that the moving is either discretionary, in which case
 * depositors are trusting a manager, or mechanical, in which case it is predictable.
 *
 * A predictable rebalancer is a standing invitation. If liquidity re-centres whenever the price leaves a fixed band,
 * anybody can compute where that happens, push the price there, and trade against a position they knew in advance was
 * about to move. The vault pays for the rebalance and the searcher takes the difference. Making the band larger helps
 * once and then the same attack runs at the new boundary.
 *
 * This band is not fixed. Every rebalance widens it, and quiet time narrows it back toward its base. So an attacker
 * who forces a move has, by forcing it, made the next move harder to force and the position they wanted to pick off
 * less concentrated. Run the attack repeatedly and it damps itself; stop, and the band tightens again on its own. The
 * width ends up tracking realised volatility, which is what a manager was being trusted to do by hand, computed from
 * the pool's own ticks rather than from anybody's judgement.
 *
 * There is no keeper. Rebalancing happens inside whichever swap pushed the price out of band, which is also the swap
 * that had a reason to. There is no manager, no allowlist and no parameter anybody can change after deployment.
 *
 * @custom:slug fungible-range
 * @custom:family Liquidity management
 * @custom:prior-art Gamma, Arrakis, Charm's Alpha Vaults and Steer wrap concentrated positions in fungible shares and move them with keepers, discretionary in some cases and on a fixed band in others. Uniswap v4 auto-rebalancing hooks remove the keeper by re-centring inside a swap. Volatility-sized ranges appear in academic market-making work and in some vault heuristics, always driven by an external estimate. Making the band's width a function of how often the position has been forced to move, so that attacking the rebalance widens the band that made the attack worth running, is the contribution here.
 * @custom:limitation The position is a single band, so this is a market maker with one opinion rather than a strategy; a pool whose price gaps a long way in one move leaves the band behind and re-centres at the new level, realising the loss exactly as any concentrated position does. Widening protects the rebalance, not the inventory. Depositors also share one position, so a rebalance's cost falls on everybody holding shares at that moment, including somebody who deposited a block earlier. And a pool with no flow never rebalances at all, since the trigger is a swap; the band is only as current as the pool is busy.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract FungibleRangeHook is ForgeHook, ERC20, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /**
     * @notice Shares permanently burned on the first deposit.
     * @dev The same defence, for the same reason, as a constant-product pair: without it the first depositor can mint
     * one share, donate to the position, and round every later depositor down to nothing.
     */
    uint256 internal constant MINIMUM_SHARES = 1_000;

    /// @notice The band's half-width when the pool has been quiet, in ticks. Rounded to the pool's spacing.
    int24 public immutable baseHalfWidth;

    /// @notice The widest the band may ever become.
    int24 public immutable maxHalfWidth;

    /// @notice How far outside the band the price must go before a rebalance fires, in basis points of the width.
    uint256 public immutable triggerBps;

    /// @notice How much wider the band gets each time it is forced to move, in basis points.
    uint256 public immutable widenBps;

    /// @notice Seconds of quiet after which the band has narrowed all the way back to {baseHalfWidth}.
    uint64 public immutable calmSeconds;

    /// @notice The pool this hook manages, bound at its first initialization.
    PoolKey public poolKey;

    /// @notice The position's lower tick. Zero-width until the first deposit.
    int24 public tickLower;

    /// @notice The position's upper tick.
    int24 public tickUpper;

    /// @notice Liquidity currently placed in the pool.
    uint128 public placed;

    /// @notice The half-width in force at the last rebalance, before any calm has narrowed it.
    int24 public halfWidthAtRebalance;

    /// @notice When the band last moved. Quiet time is measured from here.
    uint64 public lastRebalance;

    /// @notice How many times the band has been forced to move.
    uint64 public rebalances;

    /// @dev What the unlock callback is being asked to do.
    enum Op {
        Deposit,
        Withdraw,
        Rebalance
    }

    /// @dev A width of zero, or a maximum below the base, is not a band.
    error InvalidWidth();

    /// @dev Widening by nothing would leave the band fixed, which is the design this replaces.
    error InvalidWiden();

    /// @dev A trigger at or inside the band's own edge would rebalance on every swap.
    error InvalidTrigger();

    /// @dev This hook manages one pool, bound the first time one initializes with it.
    error AlreadyBound();

    /// @dev The deposit was too small to mint a share, or the withdrawal too small to return anything.
    error AmountTooSmall();

    /// @dev The first deposit must exceed the permanently locked minimum.
    error InsufficientInitialLiquidity();

    /// @dev Only the `PoolManager` may drive the unlock callback.
    error CallbackNotPoolManager();

    /// @notice Emitted when somebody deposits and receives shares.
    event Deposited(address indexed who, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted when somebody burns shares and takes their slice.
    event Withdrawn(address indexed who, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted when the band moves, with the width it moved to.
    event Rebalanced(int24 tickLower, int24 tickUpper, int24 halfWidth, uint64 count);

    constructor(
        IPoolManager _poolManager,
        int24 _baseHalfWidth,
        int24 _maxHalfWidth,
        uint256 _triggerBps,
        uint256 _widenBps,
        uint64 _calmSeconds,
        string memory shareName,
        string memory shareSymbol
    ) ForgeHook(_poolManager) ERC20(shareName, shareSymbol) {
        if (_baseHalfWidth <= 0 || _maxHalfWidth < _baseHalfWidth) revert InvalidWidth();
        if (_widenBps <= BPS) revert InvalidWiden();
        if (_triggerBps == 0 || _triggerBps > BPS) revert InvalidTrigger();
        if (_calmSeconds == 0) revert InvalidWidth();

        baseHalfWidth = _baseHalfWidth;
        maxHalfWidth = _maxHalfWidth;
        triggerBps = _triggerBps;
        widenBps = _widenBps;
        calmSeconds = _calmSeconds;
        halfWidthAtRebalance = _baseHalfWidth;
    }

    /**
     * @notice The half-width the band would use if it rebalanced right now.
     *
     * @dev Widening is remembered and calm undoes it, linearly, over {calmSeconds}. Linear rather than exponential
     * because the result has to be exact integer arithmetic that a depositor can check by hand; the shape of the
     * decay matters far less than everybody agreeing on the number.
     */
    function currentHalfWidth() public view returns (int24) {
        int24 widened = halfWidthAtRebalance;
        if (widened <= baseHalfWidth) return baseHalfWidth;

        uint256 elapsed = block.timestamp - lastRebalance;
        if (elapsed >= calmSeconds) return baseHalfWidth;

        int256 excess = int256(widened) - int256(baseHalfWidth);
        int256 remaining = (excess * uint256(calmSeconds - elapsed).toInt256()) / uint256(calmSeconds).toInt256();
        return SafeCast.toInt24(int256(baseHalfWidth) + remaining);
    }

    /// @notice Whether the price has moved far enough out of band that the next swap will re-centre the position.
    function rebalanceDue() public view returns (bool) {
        if (placed == 0) return false;

        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
        int24 centre = (tickLower + tickUpper) / 2;
        int24 half = (tickUpper - tickLower) / 2;
        if (half <= 0) return false;

        uint256 drift = _abs(tick - centre);
        return drift * BPS > uint256(_abs(half)) * triggerBps;
    }

    /// @dev Absolute value of a tick, widened first so negating the minimum cannot wrap.
    function _abs(int24 value) private pure returns (uint256) {
        int256 wide = value;
        return (wide < 0 ? -wide : wide).toUint256();
    }

    /**
     * @dev Rounds a tick down to the pool's spacing, which is the only place a position may sit.
     * @dev The truncation is the point: this is floor division, not an arithmetic ordering mistake.
     */
    function _align(int24 tick, int24 spacing) private pure returns (int24) {
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / spacing) * spacing;
        return tick < 0 && aligned != tick ? aligned - spacing : aligned;
    }

    /// @notice The band the position would occupy if it re-centred on `tick` right now.
    function bandFor(int24 tick) public view returns (int24 lower, int24 upper) {
        int24 spacing = poolKey.tickSpacing;
        int24 half = currentHalfWidth();
        lower = _align(tick - half, spacing);
        upper = _align(tick + half, spacing) + spacing;

        if (lower < TickMath.MIN_TICK) lower = _align(TickMath.MIN_TICK, spacing) + spacing;
        if (upper > TickMath.MAX_TICK) upper = _align(TickMath.MAX_TICK, spacing);
    }

    /**
     * @notice Deposit both sides and receive fungible shares in the position.
     * @dev Amounts are taken in the proportion the position currently needs, and anything left over is returned, so a
     * depositor who guessed the ratio wrong gets a smaller position rather than a failed transaction.
     */
    function deposit(uint256 amount0Desired, uint256 amount1Desired) external returns (uint256 shares) {
        if (amount0Desired == 0 && amount1Desired == 0) revert AmountTooSmall();

        IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0Desired);
        IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1Desired);

        bytes memory result =
            poolManager.unlock(abi.encode(Op.Deposit, msg.sender, amount0Desired, amount1Desired, uint256(0)));
        (uint256 used0, uint256 used1, uint128 minted) = abi.decode(result, (uint256, uint256, uint128));

        shares = _issue(msg.sender, minted);

        // Whatever the position could not take at the current ratio goes straight back.
        if (amount0Desired > used0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(msg.sender, amount0Desired - used0);
        }
        if (amount1Desired > used1) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(msg.sender, amount1Desired - used1);
        }

        emit Deposited(msg.sender, used0, used1, shares);
    }

    /// @dev Mints shares for `liquidity` added, locking the minimum on the very first deposit.
    function _issue(address to, uint128 liquidity) private returns (uint256 shares) {
        if (liquidity == 0) revert AmountTooSmall();

        uint256 supply = totalSupply();
        if (supply == 0) {
            if (liquidity <= MINIMUM_SHARES) revert InsufficientInitialLiquidity();
            _mint(address(this), MINIMUM_SHARES);
            shares = uint256(liquidity) - MINIMUM_SHARES;
        } else {
            // `placed` already includes the new liquidity, so the pre-existing amount is what shares are priced on.
            shares = (uint256(liquidity) * supply) / (uint256(placed) - liquidity);
        }

        if (shares == 0) revert AmountTooSmall();
        _mint(to, shares);
    }

    /// @notice Burn shares and take the matching slice of the position, in both currencies.
    function withdraw(uint256 shares) external returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert AmountTooSmall();

        uint256 supply = totalSupply();
        uint128 liquidity = ((uint256(placed) * shares) / supply).toUint128();
        if (liquidity == 0) revert AmountTooSmall();

        _burn(msg.sender, shares);
        bytes memory result =
            poolManager.unlock(abi.encode(Op.Withdraw, msg.sender, uint256(liquidity), uint256(0), uint256(0)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        emit Withdrawn(msg.sender, amount0, amount1, shares);
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Three operations share one callback because a hook only gets one. The discriminator is explicit rather
     * than inferred from the payload's shape, which would break the first time two shapes coincided.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();
        (Op op, address who, uint256 a, uint256 b,) = abi.decode(data, (Op, address, uint256, uint256, uint256));

        if (op == Op.Deposit) {
            (uint256 used0, uint256 used1, uint128 liquidity) = _addLiquidity(a, b);
            return abi.encode(used0, used1, liquidity);
        }
        if (op == Op.Withdraw) {
            (uint256 amount0, uint256 amount1) = _removeLiquidity(who, a.toUint128());
            return abi.encode(amount0, amount1);
        }
        _rebalance();
        return "";
    }

    /// @dev Places as much of `amount0`/`amount1` as the band can take, settling what the pool asks for.
    function _addLiquidity(uint256 amount0, uint256 amount1)
        private
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        if (placed == 0) {
            (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
            (tickLower, tickUpper) = bandFor(tick);
            lastRebalance = uint64(block.timestamp);
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity == 0) revert AmountTooSmall();

        BalanceDelta delta = _modify(int256(uint256(liquidity)));
        used0 = _settleOwed(poolKey.currency0, delta.amount0());
        used1 = _settleOwed(poolKey.currency1, delta.amount1());
        placed += liquidity;
    }

    /// @dev Removes `liquidity` and sends both sides to `who` as real tokens.
    function _removeLiquidity(address who, uint128 liquidity) private returns (uint256 amount0, uint256 amount1) {
        BalanceDelta delta = _modify(-int256(uint256(liquidity)));
        placed -= liquidity;

        amount0 = _takeOwing(poolKey.currency0, delta.amount0(), who);
        amount1 = _takeOwing(poolKey.currency1, delta.amount1(), who);
    }

    /// @dev Calls the pool, folding fees the position earned into the same delta.
    function _modify(int256 liquidityDelta) private returns (BalanceDelta) {
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        // Fees are already inside `callerDelta`; they are read only so the caller of this function need not.
        feesAccrued;
        return callerDelta;
    }

    /// @dev Pays the pool what a negative delta says is owed, from the hook's own balance.
    function _settleOwed(Currency currency, int128 amount) private returns (uint256 paid) {
        if (amount >= 0) {
            // A non-negative delta on an add means the pool owes us instead, which we take as claims.
            if (amount > 0) poolManager.mint(address(this), currency.toId(), int256(amount).toUint256());
            return 0;
        }
        paid = int256(-amount).toUint256();
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), paid);
        poolManager.settle();
    }

    /// @dev Takes what a positive delta says the pool owes, sending it to `to`.
    function _takeOwing(Currency currency, int128 amount, address to) private returns (uint256 taken) {
        if (amount <= 0) return 0;
        taken = int256(amount).toUint256();
        poolManager.take(currency, to, taken);
    }

    /**
     * @dev Moves the band to sit around the current price, and widens it for having been moved.
     *
     * Liquidity comes out and goes back in within one call, so the position is never left un-placed. What the pool
     * hands back rarely goes back in exactly, since the new band wants a different ratio; the remainder stays with
     * the hook as claims and is placed by the next deposit or rebalance rather than sitting idle in a token balance.
     */
    function _rebalance() private {
        uint128 liquidity = placed;
        if (liquidity == 0) return;

        BalanceDelta out = _modify(-int256(uint256(liquidity)));
        uint256 have0 = _creditOwing(poolKey.currency0, out.amount0());
        uint256 have1 = _creditOwing(poolKey.currency1, out.amount1());

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolKey.toId());

        // Widen first, so the band the position re-enters is already the wider one.
        int24 widened = SafeCast.toInt24((int256(currentHalfWidth()) * widenBps.toInt256()) / BPS.toInt256());
        halfWidthAtRebalance = widened > maxHalfWidth ? maxHalfWidth : widened;
        lastRebalance = uint64(block.timestamp);
        rebalances++;

        (tickLower, tickUpper) = bandFor(tick);

        uint128 replaced = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            have0,
            have1
        );
        placed = replaced;

        if (replaced > 0) {
            BalanceDelta back = _modify(int256(uint256(replaced)));
            _payFromClaims(poolKey.currency0, back.amount0());
            _payFromClaims(poolKey.currency1, back.amount1());
        }

        emit Rebalanced(tickLower, tickUpper, halfWidthAtRebalance, rebalances);
    }

    /// @dev Turns a positive delta into claims the hook holds, and reports the total it now has of that currency.
    function _creditOwing(Currency currency, int128 amount) private returns (uint256) {
        if (amount > 0) poolManager.mint(address(this), currency.toId(), int256(amount).toUint256());
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /// @dev Settles a negative delta by burning the claims the hook already holds. No token ever moves.
    function _payFromClaims(Currency currency, int128 amount) private {
        if (amount >= 0) {
            if (amount > 0) poolManager.mint(address(this), currency.toId(), int256(amount).toUint256());
            return;
        }
        poolManager.burn(address(this), currency.toId(), int256(-amount).toUint256());
    }

    /// @dev Binds the hook to the first pool that initializes with it. The position belongs to that pool alone.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (address(poolKey.hooks) != address(0)) revert AlreadyBound();
        poolKey = key;
        lastRebalance = uint64(block.timestamp);
        return this.afterInitialize.selector;
    }

    /**
     * @dev Re-centres the position if the swap just pushed the price out of band.
     *
     * After rather than before, because the trigger is where the price ended up. Rebalancing on the way in would move
     * liquidity to meet a price the swap is about to leave.
     */
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (rebalanceDue()) _rebalance();
        return (this.afterSwap.selector, int128(0));
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "FungibleRange";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "fungible-range.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "liquidity";
        tags[1] = "concentrated";
        tags[2] = "rebalancing";
        tags[3] = "keeper-free";
        tags[4] = "no-admin";
    }
}
