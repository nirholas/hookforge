// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeHook} from "../base/ForgeHook.sol";

/**
 * @title BlockBatchClearingHook
 * @notice Every swap in a block clears at one price, and orders that want opposite sides fill against each other for
 * free.
 *
 * @dev Almost all of what is called MEV is the value of being first. A continuous market prices each order at the
 * state the one before it left behind, so the right to arrive earlier is worth money, and that right is sold. Batch
 * auctions were proposed for exactly this in the equities literature, and the answer they give is not to police the
 * ordering but to abolish it: collect every order in an interval and clear them all at one uniform price. Being first
 * in a batch is worth nothing, because there is no first.
 *
 * CoW Protocol runs that design with a network of solvers off-chain. Doing it on-chain has needed a solver too, since
 * a uniform price for a batch against a bonded curve looks like a fixed point: the price depends on the net trade,
 * and the net trade depends on the price.
 *
 * For a constant-product pool it is not a fixed point. Requiring that both sides clear at one price `p` and that the
 * invariant hold gives a quadratic in `p` with an exact solution, and this hook solves it in closed form. There is no
 * solver, no auction, no bond and nobody to trust with the ordering.
 *
 * What falls out of it is the part traders will notice. Orders in opposite directions settle against each other
 * before the curve is touched at all, so matched flow pays no slippage whatsoever; only the imbalance moves the
 * price. A block where buyers and sellers are evenly matched clears at the spot price for everybody, which is a thing
 * a continuous AMM cannot do at any size.
 *
 * The cost is that a swap does not return tokens. It returns a claim on a batch that has not cleared yet, and the
 * trader collects afterwards. That is the honest price of not having an ordering to sell.
 *
 * @custom:slug block-batch-clearing
 * @custom:family Order flow and MEV
 * @custom:prior-art Frequent batch auctions are Budish, Cramton and Shim's answer to the equities latency race. CoW Protocol clears uniform-price batches with off-chain solvers, and Gnosis ran an on-chain batch exchange over an order book. On v4, TWAMM spreads one order over time and various hooks reorder or tax within a block. Clearing a whole block's flow against a bonded curve at one uniform price, solved in closed form on-chain with no solver and no auction, is the contribution here.
 * @custom:limitation A swap returns nothing at the moment it is made, so this cannot be routed through by an aggregator expecting tokens back and is unusable for anything atomic. Orders are exact-input only, for the same reason an exact output cannot be promised before the price is known. A batch also clears when somebody touches the pool in a later block, so the last batch of a quiet period waits for the next swap or for anybody to call `clear`; the trader's funds are held meanwhile. And the uniform price is uniform within a block, which means the ordering advantage is gone but the choice of which block to be in is not.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract BlockBatchClearingHook is ForgeHook, ERC20, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Fixed point one, which prices are quoted in.
    uint256 internal constant WAD = 1e18;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Shares permanently burned on the first deposit, against the usual donation front-run.
    uint256 internal constant MINIMUM_SHARES = 1_000;

    /// @notice One order in a batch.
    struct Order {
        /// @notice Who placed it and who collects.
        address owner;
        /// @notice Whether it pays currency0 to receive currency1.
        bool zeroForOne;
        /// @notice What it paid in.
        uint128 amountIn;
        /// @notice Whether it has been collected.
        bool collected;
    }

    /// @notice A block's worth of orders, and the price they all cleared at.
    struct Batch {
        /// @notice The block these orders arrived in.
        uint64 blockNumber;
        /// @notice Currency0 paid in across the batch.
        uint128 in0;
        /// @notice Currency1 paid in across the batch.
        uint128 in1;
        /// @notice The uniform clearing price, as currency1 per currency0, in wad. Zero until it clears.
        uint256 price;
        /// @notice Whether it has cleared.
        bool cleared;
    }

    /// @notice The pool this hook serves, bound at its first initialization.
    PoolKey public poolKey;

    /// @notice The swap fee, in basis points, which stays in the reserves and therefore in every share.
    uint256 public immutable swapFeeBps;

    /// @notice Reserves backing the curve, held as claims on the manager.
    uint256 public reserve0;

    /// @notice As {reserve0}, for currency1.
    uint256 public reserve1;

    /// @notice Batches by index, oldest first.
    mapping(uint256 => Batch) public batchOf;

    /// @notice Orders within a batch.
    mapping(uint256 => mapping(uint256 => Order)) public orderOf;

    /// @notice How many orders a batch holds.
    mapping(uint256 => uint256) public orderCount;

    /// @notice How many batches have ever been opened.
    uint256 public batchCount;

    /// @dev A fee at or above the whole trade is not a fee.
    error InvalidFee();

    /// @dev This hook serves one pool, bound the first time one initializes with it.
    error AlreadyBound();

    /// @dev Liquidity belongs to the hook, not to the pool, so the pool's own path is closed.
    error AddLiquidityThroughHook();

    /// @dev A batch cannot promise an exact output before it knows the price everybody clears at.
    error ExactOutputUnsupported();

    /// @dev The pool holds nothing, so there is nothing to clear against.
    error NoReserves();

    /// @dev The deposit was too small to mint a share, or the withdrawal too small to return anything.
    error AmountTooSmall();

    /// @dev The first deposit must exceed the permanently locked minimum.
    error InsufficientInitialLiquidity();

    /// @dev The batch is still open, so there is no price yet.
    error NotCleared();

    /// @dev The order does not exist, or has already been collected.
    error NothingToCollect();

    /// @dev Only the `PoolManager` may drive the unlock callback.
    error CallbackNotPoolManager();

    /// @notice Emitted when an order joins a batch.
    event Ordered(uint256 indexed batch, uint256 indexed order, address indexed owner, bool zeroForOne, uint256 amountIn);

    /// @notice Emitted when a batch clears, with the one price everybody in it got.
    event Cleared(uint256 indexed batch, uint256 price, uint256 in0, uint256 in1, uint256 matched);

    /// @notice Emitted when a trader collects what their order bought.
    event Collected(uint256 indexed batch, uint256 indexed order, address indexed owner, uint256 amountOut);

    constructor(IPoolManager _poolManager, uint256 _swapFeeBps, string memory name_, string memory symbol_)
        ForgeHook(_poolManager)
        ERC20(name_, symbol_)
    {
        if (_swapFeeBps >= BPS) revert InvalidFee();
        swapFeeBps = _swapFeeBps;
    }

    /// @notice The batch currently taking orders, which is the newest one.
    function openBatch() public view returns (uint256) {
        return batchCount == 0 ? 0 : batchCount - 1;
    }

    /// @notice Whether the open batch is from an earlier block and is therefore ready to clear.
    function clearable() public view returns (bool) {
        if (batchCount == 0) return false;
        Batch memory batch = batchOf[batchCount - 1];
        return !batch.cleared && batch.blockNumber < uint64(block.number) && (batch.in0 > 0 || batch.in1 > 0);
    }

    /**
     * @notice The price a batch of `in0` and `in1` would clear at against the current reserves, in wad.
     *
     * @dev The closed form. Requiring that currency0 sellers receive `in0 * p` and currency1 sellers receive
     * `in1 / p`, and that the constant product hold afterwards, gives
     *
     *   p^2 * u(x + u) - p * (x*v + u*y + 2*u*v) + v(y + v) = 0
     *
     * for reserves `x`, `y` and fee-adjusted inputs `u`, `v`. The larger root is the physical one; the smaller is the
     * reflection where both sides trade the wrong way. A batch with nothing on one side degenerates to an ordinary
     * constant-product swap and is solved as one.
     */
    function clearingPrice(uint256 in0, uint256 in1) public view returns (uint256) {
        uint256 x = reserve0;
        uint256 y = reserve1;
        if (x == 0 || y == 0) revert NoReserves();

        uint256 u = (in0 * (BPS - swapFeeBps)) / BPS;
        uint256 v = (in1 * (BPS - swapFeeBps)) / BPS;

        if (u == 0 && v == 0) return (y * WAD) / x;
        // One-sided batches are plain swaps, and the quadratic degenerates for them, so they are solved directly.
        if (u == 0) return ((y + v) * WAD) / x;
        if (v == 0) return (y * WAD) / (x + u);

        return _solve(x, y, u, v);
    }

    /// @dev The one-sided price for a batch whose other side is too small to matter, at full precision.
    function _oneSided(uint256 x, uint256 y, uint256 u, uint256 v, bool zeroSideEmpty)
        private
        pure
        returns (uint256)
    {
        return zeroSideEmpty ? ((y + v) * WAD) / x : (y * WAD) / (x + u);
    }

    /**
     * @dev The larger root, computed on scaled-down inputs.
     *
     * The price is a ratio, so scaling every quantity by the same factor leaves it unchanged. Doing that keeps the
     * discriminant inside a uint256 for reserves of any realistic size, which it would not be otherwise: the squared
     * term reaches ten to the ninety-sixth on raw eighteen-decimal balances.
     */
    function _solve(uint256 x, uint256 y, uint256 u, uint256 v) private pure returns (uint256) {
        uint256 largest = x > y ? x : y;
        if (u > largest) largest = u;
        if (v > largest) largest = v;

        uint256 scale = largest > 1e18 ? (largest / 1e18) + 1 : 1;
        uint256 sx = x / scale;
        uint256 sy = y / scale;
        uint256 su = u / scale;
        uint256 sv = v / scale;

        // A side that does not survive the scaling contributes less than this arithmetic can represent, so the batch
        // is effectively one-sided and is priced as one, at full precision. Reverting instead would have let anybody
        // stop a whole batch from clearing with a one-wei order.
        if (su == 0) return _oneSided(x, y, u, v, true);
        if (sv == 0) return _oneSided(x, y, u, v, false);
        if (sx == 0 || sy == 0) revert NoReserves();

        uint256 a = su * (sx + su);
        uint256 b = sx * sv + su * sy + 2 * su * sv;
        uint256 c = sv * (sy + sv);

        uint256 discriminant = b * b - 4 * a * c;
        return ((b + _sqrt(discriminant)) * WAD) / (2 * a);
    }

    /// @dev Integer square root. Babylonian method.
    function _sqrt(uint256 n) private pure returns (uint256 result) {
        if (n == 0) return 0;
        uint256 z = (n + 1) / 2;
        result = n;
        while (z < result) {
            result = z;
            z = (n / z + z) / 2;
        }
    }

    /**
     * @notice Clear the open batch if it is from an earlier block. Callable by anyone.
     * @dev Runs automatically at the front of the next swap. This is the path for a pool that has gone quiet, where a
     * batch would otherwise sit unfilled waiting for somebody to trade.
     */
    function clear() external {
        _clearIfDue();
    }

    /// @dev Clears the open batch when it belongs to a past block. Pure arithmetic; the reserves are already held.
    function _clearIfDue() private {
        if (!clearable()) return;

        uint256 index = batchCount - 1;
        Batch storage batch = batchOf[index];

        uint256 price = clearingPrice(batch.in0, batch.in1);
        uint256 u = (uint256(batch.in0) * (BPS - swapFeeBps)) / BPS;
        uint256 v = (uint256(batch.in1) * (BPS - swapFeeBps)) / BPS;

        uint256 out1 = (u * price) / WAD;
        uint256 out0 = v == 0 ? 0 : (v * WAD) / price;

        // Both sides are paid out of the reserves, which have already received everything the batch paid in.
        if (out0 > reserve0 + batch.in0 || out1 > reserve1 + batch.in1) revert NoReserves();
        reserve0 = reserve0 + batch.in0 - out0;
        reserve1 = reserve1 + batch.in1 - out1;

        batch.price = price;
        batch.cleared = true;

        // How much of the batch never touched the curve, which is what the matching saved everybody.
        uint256 matched = out1 < batch.in1 ? out1 : batch.in1;
        emit Cleared(index, price, batch.in0, batch.in1, matched);
    }

    /// @notice What an order is owed once its batch has cleared.
    function owed(uint256 batch, uint256 order) public view returns (uint256) {
        Order memory placed = orderOf[batch][order];
        Batch memory settled = batchOf[batch];
        if (placed.owner == address(0) || placed.collected || !settled.cleared) return 0;

        uint256 net = (uint256(placed.amountIn) * (BPS - swapFeeBps)) / BPS;
        return placed.zeroForOne ? (net * settled.price) / WAD : (net * WAD) / settled.price;
    }

    /// @notice Collect what an order bought, as real tokens.
    function collect(uint256 batch, uint256 order) external returns (uint256 amount) {
        Order storage placed = orderOf[batch][order];
        if (placed.owner == address(0) || placed.collected) revert NothingToCollect();
        if (!batchOf[batch].cleared) revert NotCleared();

        amount = owed(batch, order);
        placed.collected = true;
        if (amount == 0) revert NothingToCollect();

        Currency currency = placed.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        poolManager.unlock(abi.encode(currency, placed.owner, amount));

        emit Collected(batch, order, placed.owner, amount);
    }

    /// @notice Deposit both sides and receive shares in the curve the batches clear against.
    function deposit(uint256 amount0, uint256 amount1) external returns (uint256 shares) {
        if (amount0 == 0 || amount1 == 0) revert AmountTooSmall();

        uint256 supply = totalSupply();
        if (supply == 0) {
            uint256 minted = _sqrt(amount0 * amount1);
            if (minted <= MINIMUM_SHARES) revert InsufficientInitialLiquidity();
            _mint(address(this), MINIMUM_SHARES);
            shares = minted - MINIMUM_SHARES;
        } else {
            uint256 shares0 = (amount0 * supply) / reserve0;
            uint256 shares1 = (amount1 * supply) / reserve1;
            shares = shares0 < shares1 ? shares0 : shares1;
        }
        if (shares == 0) revert AmountTooSmall();

        IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        poolManager.unlock(abi.encode(Currency.wrap(address(0)), address(0), uint256(0)));

        reserve0 += amount0;
        reserve1 += amount1;
        _mint(msg.sender, shares);
    }

    /// @notice Burn shares and take a pro-rata slice of the reserves.
    function withdraw(uint256 shares) external returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert AmountTooSmall();

        uint256 supply = totalSupply();
        amount0 = (reserve0 * shares) / supply;
        amount1 = (reserve1 * shares) / supply;
        if (amount0 == 0 && amount1 == 0) revert AmountTooSmall();

        _burn(msg.sender, shares);
        reserve0 -= amount0;
        reserve1 -= amount1;

        if (amount0 > 0) poolManager.unlock(abi.encode(poolKey.currency0, msg.sender, amount0));
        if (amount1 > 0) poolManager.unlock(abi.encode(poolKey.currency1, msg.sender, amount1));
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Two shapes share one callback because a hook only gets one: paying somebody out of the hook's claims, and
     * turning the hook's own token balance into claims after a deposit. The zero address distinguishes them.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));

        if (to == address(0)) {
            _depositToClaims(poolKey.currency0);
            _depositToClaims(poolKey.currency1);
            return "";
        }

        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    /// @dev Moves whatever the hook holds of a currency into claims, which is how the reserves are kept.
    function _depositToClaims(Currency currency) private {
        uint256 held = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (held == 0) return;
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), held);
        poolManager.settle();
        poolManager.mint(address(this), currency.toId(), held);
    }

    /// @dev Binds the hook to the first pool that initializes with it.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (address(poolKey.hooks) != address(0)) revert AlreadyBound();
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    /// @dev Liquidity is held by the hook, so the pool's own path would strand it in the singleton.
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
     * @dev Takes the order's input and gives nothing back, which is what deferring means.
     *
     * The previous block's batch is cleared first, so a trader whose order opens a new batch has already paid for
     * settling the last one and nobody has to be paid to do it separately.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) revert ExactOutputUnsupported();
        _clearIfDue();

        uint256 amountIn = uint256(-params.amountSpecified);
        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        poolManager.mint(address(this), currencyIn.toId(), amountIn);

        // A swap reaches the hook from a router, so the owner may be named in hookData. Naming somebody else gives
        // away your own fill, which is the only thing a forged attribution achieves.
        address owner = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;
        _record(owner, params.zeroForOne, amountIn);

        return (this.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(amountIn.toInt256()), int128(0)), 0);
    }

    /// @dev Files an order in the batch for the current block, opening one if this is the block's first.
    function _record(address owner, bool zeroForOne, uint256 amountIn) private {
        uint256 index;
        if (batchCount == 0 || batchOf[batchCount - 1].blockNumber != uint64(block.number)) {
            index = batchCount++;
            batchOf[index].blockNumber = uint64(block.number);
        } else {
            index = batchCount - 1;
        }

        Batch storage batch = batchOf[index];
        if (zeroForOne) batch.in0 += amountIn.toUint128();
        else batch.in1 += amountIn.toUint128();

        uint256 order = orderCount[index]++;
        orderOf[index][order] =
            Order({owner: owner, zeroForOne: zeroForOne, amountIn: amountIn.toUint128(), collected: false});

        emit Ordered(index, order, owner, zeroForOne, amountIn);
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
        return "BlockBatchClearing";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "block-batch-clearing.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "mev";
        tags[1] = "batch-auction";
        tags[2] = "uniform-price";
        tags[3] = "order-flow";
        tags[4] = "no-admin";
    }
}
