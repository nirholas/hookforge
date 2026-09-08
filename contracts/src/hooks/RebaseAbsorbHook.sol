// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeHook} from "../base/ForgeHook.sol";

/**
 * @title RebaseAbsorbHook
 * @notice A pool whose reserves are real tokens it holds itself, so anything that happens to those tokens happens to
 * the people who supplied them.
 *
 * @dev Uniswap v4 keeps every pool's tokens in one singleton and tracks ownership as ERC-6909 claims. That is what
 * makes it cheap, and it has a consequence nobody has been able to work around: a claim does not rebase. If a
 * rebasing token gains supply, the gain lands on the singleton's balance, where it belongs to no pool in particular
 * and cannot be attributed to one, because the singleton holds the same token for every pool that trades it. The same
 * is true of a dividend paid to holders, and of an airdrop. The value arrives and strands.
 *
 * That is a property of where the tokens sit, not of v4. A hook serving one pool is not a singleton. If the reserves
 * live at the hook's own address, every one of those events is unambiguous: there is exactly one pool it could belong
 * to, and its providers own it in proportion to their shares, with no accounting to do at all. The reserve is simply
 * read as the balance, so a rebase up is already in the next quote and a rebase down is already priced in. Nothing
 * has to notice.
 *
 * Holding real tokens costs more gas per swap than holding claims, and that is the whole trade. It is the right trade
 * for exactly the tokens the claims model cannot serve.
 *
 * The same measurement makes fee-on-transfer tokens work, which is a second thing v4 cannot do. Because the hook
 * quotes from what it actually received rather than from what the trader said they sent, a token that taxes its own
 * transfers is priced correctly with no configuration, no oracle, and nothing to keep up to date when the token
 * changes its own fee.
 *
 * @custom:slug rebase-absorb
 * @custom:family Curves
 * @custom:prior-art Wrappers are the standard answer: wstETH wraps a rebasing token into a fixed-balance one, and every AMM that supports fee-on-transfer tokens (Uniswap v2's supporting-fee router onwards) does so by measuring balances in the router. On v4 the received wisdom is that rebasing tokens need a wrapper, because the singleton cannot attribute a supply change to a pool. Moving the reserves to a per-pool hook address, so that the attribution question does not arise and the balance itself is the reserve, is the contribution here. It also covers what this catalogue listed separately as DividendPassthrough, since a dividend paid to holders is the same event as a rebase from the pool's point of view.
 * @custom:limitation Real transfers on every swap, which is more gas than the claims model and the reason v4 does not do this by default. Exact-output swaps are refused outright rather than approximated: a taxed transfer cannot deliver an exact amount to the recipient, so promising one would be a lie the contract could not keep. A taxed input needs a router that over-sends, as explained above, and is outside what a hook can fix. One swap's input is also held as a claim until the next swap or a `sweep` converts it, and a rebase that lands in that window applies to everything except that amount. Reading the balance as the reserve also means a direct transfer to the hook is a donation to every share, which is harmless but is a way to move share value without a deposit. A token that can seize or freeze balances can do so here, exactly as it can anywhere else it is held. And only the pool's own two tokens are absorbed; an airdrop of a third token sits at the hook address with no way to reach anybody.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract RebaseAbsorbHook is ForgeHook, ERC20, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Shares permanently burned on the first deposit, against the usual donation front-run.
    uint256 internal constant MINIMUM_SHARES = 1_000;

    /// @notice The swap fee, in basis points, kept in the reserves and therefore in every share.
    uint256 public immutable swapFeeBps;

    /// @notice The pool this hook serves, bound at its first initialization.
    PoolKey public poolKey;

    /// @dev A fee at or above the whole trade is not a fee.
    error InvalidFee();

    /// @dev This hook serves one pool, bound the first time one initializes with it.
    error AlreadyBound();

    /// @dev Liquidity belongs to the hook, not to the pool, so the pool's own path is closed.
    error AddLiquidityThroughHook();

    /// @dev An exact-output swap cannot promise an exact receipt when the token taxes its own transfers.
    error ExactOutputUnsupported();

    /// @dev The pool has no reserves to quote against yet.
    error NoReserves();

    /// @dev The deposit was too small to mint a share, or the withdrawal too small to return anything.
    error AmountTooSmall();

    /// @dev The first deposit must exceed the permanently locked minimum.
    error InsufficientInitialLiquidity();

    /// @dev Only the `PoolManager` may drive the unlock callback.
    error CallbackNotPoolManager();

    /// @notice Emitted on every swap, with what the hook actually received rather than what was asked for.
    event Swapped(address indexed sender, bool zeroForOne, uint256 received, uint256 sent);

    /// @notice Emitted when somebody deposits and receives shares.
    event Deposited(address indexed who, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted when somebody burns shares and takes their slice.
    event Withdrawn(address indexed who, uint256 amount0, uint256 amount1, uint256 shares);

    constructor(IPoolManager _poolManager, uint256 _swapFeeBps, string memory shareName, string memory shareSymbol)
        ForgeHook(_poolManager)
        ERC20(shareName, shareSymbol)
    {
        if (_swapFeeBps >= BPS) revert InvalidFee();
        swapFeeBps = _swapFeeBps;
    }

    /**
     * @notice The pool's reserves: the tokens the hook holds, plus anything still owed to it by the manager.
     *
     * @dev The token balance is the mechanism. There is no stored reserve to drift from reality, so a rebase, a
     * dividend, a transfer tax and a plain donation are all accounted for by the time anybody asks.
     *
     * The claims term is the one piece of bookkeeping. A swap's input cannot be collected as real tokens while the
     * swap is running, because the router has not settled it to the manager yet, so it is collected as a claim and
     * converted at the start of the next swap. At most one swap's input is ever in that state, and {sweep} converts
     * it on demand. It is counted here so a quote is never taken against a reserve that understates itself.
     */
    function reserves() public view returns (uint256 reserve0, uint256 reserve1) {
        reserve0 = _holdingOf(poolKey.currency0);
        reserve1 = _holdingOf(poolKey.currency1);
    }

    /// @dev Tokens held plus claims outstanding, for one currency.
    function _holdingOf(Currency currency) private view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this))
            + poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice How much of each reserve is still a claim rather than a token, and so has not felt a rebase yet.
    function pendingClaims() public view returns (uint256 claims0, uint256 claims1) {
        claims0 = poolManager.balanceOf(address(this), poolKey.currency0.toId());
        claims1 = poolManager.balanceOf(address(this), poolKey.currency1.toId());
    }

    /**
     * @notice Convert every outstanding claim into real tokens. Callable by anyone.
     * @dev Runs automatically at the start of each swap. This is the path for a pool between swaps, where a rebase
     * would otherwise miss whatever the last swap left as a claim.
     */
    function sweep() external {
        poolManager.unlock("");
    }

    /// @dev Burns the hook's claims and takes the tokens behind them. Must run inside a lock.
    function _sweep() private {
        _sweepOne(poolKey.currency0);
        _sweepOne(poolKey.currency1);
    }

    /// @dev As {_sweep}, for one currency. A claim is always backed, so this cannot fail for want of balance.
    function _sweepOne(Currency currency) private {
        uint256 held = poolManager.balanceOf(address(this), currency.toId());
        if (held == 0) return;
        poolManager.burn(address(this), currency.toId(), held);
        poolManager.take(currency, address(this), held);
    }

    /// @notice The constant-product quote for `amountIn`, net of the swap fee.
    function quote(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        return _quoteFrom(reserveIn, reserveOut, amountIn);
    }

    /// @dev Constant product with the fee taken off the input, which is where it stays.
    function _quoteFrom(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) private view returns (uint256) {
        if (reserveIn == 0 || reserveOut == 0) revert NoReserves();
        if (amountIn == 0) return 0;

        uint256 afterFee = amountIn * (BPS - swapFeeBps);
        return (afterFee * reserveOut) / (reserveIn * BPS + afterFee);
    }

    /// @notice Deposit both sides and receive shares. Amounts are trimmed to the reserve ratio.
    function deposit(uint256 amount0Desired, uint256 amount1Desired) external returns (uint256 shares) {
        poolManager.unlock("");
        (uint256 reserve0, uint256 reserve1) = reserves();
        uint256 supply = totalSupply();

        // Measured rather than assumed, so a token that taxes the deposit credits only what turned up.
        uint256 got0 = _pullMeasured(poolKey.currency0, amount0Desired);
        uint256 got1 = _pullMeasured(poolKey.currency1, amount1Desired);

        if (supply == 0) {
            uint256 minted = _sqrt(got0 * got1);
            if (minted <= MINIMUM_SHARES) revert InsufficientInitialLiquidity();
            _mint(address(this), MINIMUM_SHARES);
            shares = minted - MINIMUM_SHARES;
        } else {
            uint256 shares0 = reserve0 == 0 ? type(uint256).max : (got0 * supply) / reserve0;
            uint256 shares1 = reserve1 == 0 ? type(uint256).max : (got1 * supply) / reserve1;
            shares = shares0 < shares1 ? shares0 : shares1;
        }
        if (shares == 0) revert AmountTooSmall();

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, got0, got1, shares);
    }

    /// @notice Burn shares and take a pro-rata slice of both reserves, whatever they have become.
    function withdraw(uint256 shares) external returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert AmountTooSmall();

        // Claims cannot be transferred out, so they are converted before a withdrawal is priced or paid.
        poolManager.unlock("");
        uint256 supply = totalSupply();
        (uint256 reserve0, uint256 reserve1) = reserves();

        amount0 = (reserve0 * shares) / supply;
        amount1 = (reserve1 * shares) / supply;
        if (amount0 == 0 && amount1 == 0) revert AmountTooSmall();

        _burn(msg.sender, shares);
        if (amount0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(msg.sender, amount1);

        emit Withdrawn(msg.sender, amount0, amount1, shares);
    }

    /// @dev Pulls `amount` from the caller and reports what actually arrived.
    function _pullMeasured(Currency currency, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        return token.balanceOf(address(this)) - before;
    }

    /// @dev Integer square root, for the geometric mean the first deposit mints. Babylonian method.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev Binds the hook to the first pool that initializes with it.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (address(poolKey.hooks) != address(0)) revert AlreadyBound();
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    /// @dev Liquidity is held by the hook, so the pool's own liquidity path would strand it in the singleton.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    /// @dev As {_beforeAddLiquidity}. Withdrawals go through {withdraw}.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    /**
     * @dev Takes the whole swap, quoting from what actually arrived.
     *
     * The order matters and is the point. The input is taken into the hook first and the reserves are read before
     * that happens, so the quote is computed from a real receipt against a real prior reserve. A hook that quoted
     * first and settled afterwards would be trusting the trader's number, which is exactly the assumption a
     * fee-on-transfer token breaks.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) revert ExactOutputUnsupported();

        uint256 asked = uint256(-params.amountSpecified);
        uint256 amountOut = _fill(key, params.zeroForOne, asked, sender);

        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(SafeCast.toInt128(asked.toInt256()), -SafeCast.toInt128(amountOut.toInt256())),
            0
        );
    }

    /**
     * @dev Collects the input, quotes from it, and pays the output out of the hook's own tokens.
     *
     * The sweep comes first so the reserves this quote is taken against are entirely real tokens, which is what
     * makes a rebase since the last swap already part of the price. The input is then collected as a claim, because
     * the router has not settled it to the manager yet and there is nothing there to take.
     */
    function _fill(PoolKey calldata key, bool zeroForOne, uint256 asked, address sender) private returns (uint256) {
        _sweep();

        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        (uint256 reserve0, uint256 reserve1) = reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        poolManager.mint(address(this), currencyIn.toId(), asked);
        uint256 amountOut = _quoteFrom(reserveIn, reserveOut, asked);

        uint256 delivered;
        if (amountOut > 0) {
            // `settle` reports what the manager was actually credited, which is what the token let through rather
            // than what was sent. Declaring the delta from that figure is what makes a taxed output balance: a hook
            // that promised the gross amount would be short by the tax and the whole swap would revert.
            poolManager.sync(currencyOut);
            IERC20(Currency.unwrap(currencyOut)).safeTransfer(address(poolManager), amountOut);
            delivered = poolManager.settle();
        }

        emit Swapped(sender, zeroForOne, asked, delivered);
        return delivered;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();
        _sweep();
        return "";
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function hookName() external pure override returns (string memory) {
        return "RebaseAbsorb";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "rebase-absorb.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "curve";
        tags[1] = "rebasing";
        tags[2] = "fee-on-transfer";
        tags[3] = "custom-curve";
        tags[4] = "no-admin";
    }
}
