// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {ForgeHook} from "../base/ForgeHook.sol";

/**
 * @title StreamDCAHook
 * @notice A standing order that buys more when the price falls, settled inside other people's swaps.
 *
 * @dev Every on-chain recurring buy built so far spends a fixed amount per period. That is dollar-cost averaging, and
 * it is popular because it is easy to explain rather than because it is good: it spends the same money whether the
 * asset just halved or just doubled, which is to say it treats the two identically and buys the most units in exactly
 * the periods that matter least.
 *
 * The strategy that fixes this is older than crypto. Value averaging, described by Michael Edleson in 1988, commits
 * to growing the *position* by a fixed amount each period rather than spending a fixed amount. If the price fell, the
 * position is behind its target and the period buys more; if it rose, the position is ahead and the period buys less
 * or nothing. It beats dollar-cost averaging on essentially every historical series, and it has not been built
 * on-chain because it needs a price at every period and a recomputation per participant, which is exactly the shape
 * of thing a keeper bot is bad at and a hook is good at.
 *
 * A stream here names a budget, a period, and how much value the position should gain each period. Nothing runs on a
 * schedule: due streams are settled inside the next swap anybody makes on the pool, in one batched trade per
 * direction, priced by the pool itself. That batching is what makes it affordable, and it is also what makes it fair,
 * since every stream due in the same block gets the same price rather than a queue position.
 *
 * The reference price is the pool's own. That is deliberate and it is the sharp edge: a manipulated pool price makes
 * a stream buy the wrong amount, so this belongs on pools deep enough that moving them costs more than the streams
 * behind them are worth.
 *
 * @custom:slug stream-dca
 * @custom:family Order types
 * @custom:prior-art TWAMM, both the original paper and the v4 hooks implementing it, splits a large order over time at a constant rate. Mean Finance and the DCA protocols run keeper bots on fixed-size periodic buys. Sablier and Superfluid stream tokens without trading them. Value averaging itself is a 1988 equity strategy with no on-chain implementation. Making the per-period amount a function of how far the position is from its target value, priced by the pool and settled in batches inside unrelated swaps, is the contribution here.
 * @custom:limitation The pool's own price is the reference, so a pool shallow enough to move cheaply is a pool where streams can be made to buy at the wrong size; this belongs on deep pools. Streams settle when somebody swaps, so a pool with no flow leaves them late until anybody calls `poke`, and a late period is executed at the price it is finally seen at rather than the price it was due at. Work per swap is capped, so a pool with more due streams than the cap catches up over several swaps rather than all at once. A stream can also finish under budget, since a position that keeps running ahead of target never spends the rest.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract StreamDCAHook is ForgeHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Fixed point one, in the Q96 format v4 quotes prices in.
    uint256 internal constant Q96 = 1 << 96;

    /**
     * @notice The most streams one swap will settle.
     * @dev A bound, not a preference. Settling an unbounded list inside somebody else's swap makes their gas a
     * function of how many strangers opened a stream, which is a denial of service dressed as a feature.
     */
    uint256 public constant MAX_PER_SWAP = 8;

    /// @notice A standing value-averaging order.
    struct Stream {
        /// @notice Who opened it, and who the proceeds belong to.
        address owner;
        /// @notice Whether it spends currency0 to acquire currency1.
        bool zeroForOne;
        /// @notice Budget not yet spent, in the currency being spent.
        uint128 remaining;
        /// @notice What the position has bought so far, in the currency being acquired.
        uint128 acquired;
        /// @notice How much the position's value should gain each period, in the currency being spent.
        uint128 targetPerPeriod;
        /// @notice Seconds in a period.
        uint64 periodLength;
        /// @notice When the stream began. Periods are counted from here.
        uint64 startedAt;
        /// @notice Periods already settled.
        uint32 periodsDone;
        /// @notice Total periods the stream runs for.
        uint32 periods;
    }

    /// @notice Every stream ever opened on a pool, by index.
    mapping(PoolId => mapping(uint256 => Stream)) public streamOf;

    /// @notice How many streams have been opened on a pool.
    mapping(PoolId => uint256) public streamCount;

    /// @dev Where the next scan starts, so a long list is worked through evenly rather than from the top each time.
    mapping(PoolId => uint256) private _cursor;

    /// @dev Set while the hook is running its own swap, so it does not recurse into settling streams again.
    bool private _settling;

    /// @dev What the unlock callback is being asked to do. A hook gets one callback and this needs two things from it.
    enum Op {
        Poke,
        Withdraw
    }

    /// @dev A stream with no budget, no periods, or a zero-length period is not a stream.
    error InvalidStream();

    /// @dev Only the account that opened a stream may change or close it.
    error NotYourStream();

    /// @dev There is no stream at that index on this pool.
    error NoSuchStream();

    /// @dev The stream has nothing left to withdraw.
    error NothingToWithdraw();

    /// @dev Only the `PoolManager` may drive the unlock callback.
    error CallbackNotPoolManager();

    /// @notice Emitted when a stream is opened.
    event Opened(
        PoolId indexed id,
        uint256 indexed stream,
        address indexed owner,
        bool zeroForOne,
        uint128 budget,
        uint128 targetPerPeriod,
        uint64 periodLength,
        uint32 periods
    );

    /// @notice Emitted each time a stream buys, with the periods it caught up on.
    event Executed(PoolId indexed id, uint256 indexed stream, uint256 spent, uint256 received, uint32 periodsDone);

    /// @notice Emitted when a stream's owner takes what it bought and whatever budget is left.
    event Closed(PoolId indexed id, uint256 indexed stream, uint256 acquired, uint256 refunded);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /**
     * @notice Open a value-averaging stream on a pool.
     *
     * @dev The budget is pulled immediately and held by the hook. What the stream buys is held as claims on the
     * `PoolManager` until the owner closes it, which is what makes each execution cost a fraction of a real transfer.
     *
     * @param key The pool.
     * @param zeroForOne Whether to spend currency0 and acquire currency1.
     * @param budget The most this stream will ever spend.
     * @param targetPerPeriod How much the position's value should gain each period, in the currency being spent.
     * @param periodLength Seconds per period.
     * @param periods How many periods the stream runs for.
     * @return stream The index of the new stream on this pool.
     */
    function open(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 budget,
        uint128 targetPerPeriod,
        uint64 periodLength,
        uint32 periods
    ) external returns (uint256 stream) {
        if (budget == 0 || targetPerPeriod == 0 || periodLength == 0 || periods == 0) revert InvalidStream();

        PoolId id = key.toId();
        stream = streamCount[id]++;
        streamOf[id][stream] = Stream({
            owner: msg.sender,
            zeroForOne: zeroForOne,
            remaining: budget,
            acquired: 0,
            targetPerPeriod: targetPerPeriod,
            periodLength: periodLength,
            startedAt: uint64(block.timestamp),
            periodsDone: 0,
            periods: periods
        });

        Currency spend = zeroForOne ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(spend)).safeTransferFrom(msg.sender, address(this), budget);

        emit Opened(id, stream, msg.sender, zeroForOne, budget, targetPerPeriod, periodLength, periods);
    }

    /**
     * @notice Close a stream, taking what it bought and whatever budget it never spent.
     * @dev Callable at any point, including mid-schedule. A stream is an instruction, not a lockup.
     */
    function close(PoolKey calldata key, uint256 stream) external {
        PoolId id = key.toId();
        Stream memory s = streamOf[id][stream];
        if (s.owner == address(0)) revert NoSuchStream();
        if (s.owner != msg.sender) revert NotYourStream();
        if (s.acquired == 0 && s.remaining == 0) revert NothingToWithdraw();

        delete streamOf[id][stream];

        Currency spend = s.zeroForOne ? key.currency0 : key.currency1;
        Currency acquire = s.zeroForOne ? key.currency1 : key.currency0;

        if (s.remaining > 0) IERC20(Currency.unwrap(spend)).safeTransfer(s.owner, s.remaining);
        if (s.acquired > 0) poolManager.unlock(abi.encode(Op.Withdraw, acquire, s.owner, uint256(s.acquired)));

        emit Closed(id, stream, s.acquired, s.remaining);
    }

    /**
     * @notice Settle whatever streams are due, without swapping.
     *
     * @dev Streams normally ride along inside somebody else's swap and cost their owner nothing. This is the path for
     * a pool with no flow, where waiting for a swap would mean waiting indefinitely. Anybody may call it.
     *
     * It has to open its own lock. Settling trades through the pool, and the `PoolManager` only accepts that from
     * inside an `unlock`; the swap path is already inside the swapper's.
     */
    function poke(PoolKey calldata key) external {
        poolManager.unlock(abi.encode(Op.Poke, key));
    }

    /// @notice How many periods a stream is currently owed, which is what the next execution will catch up on.
    function periodsDue(PoolKey calldata key, uint256 stream) public view returns (uint32) {
        Stream memory s = streamOf[key.toId()][stream];
        if (s.owner == address(0)) return 0;
        return _elapsed(s) - s.periodsDone;
    }

    /// @dev Periods that have passed since the stream began, capped at its length.
    function _elapsed(Stream memory s) private view returns (uint32) {
        uint256 count = (block.timestamp - s.startedAt) / s.periodLength;
        return count >= s.periods ? s.periods : count.toUint32();
    }

    /**
     * @notice What a stream would spend right now, at the pool's current price.
     *
     * @dev This is the value-averaging rule in one function. The target is what the position should be worth by now;
     * the holding is what it is actually worth at the pool's price; the difference is the buy. A position that ran
     * ahead of its target buys nothing this period, which is the strategy working rather than a stall.
     */
    function spendDue(PoolKey calldata key, uint256 stream) public view returns (uint256) {
        PoolId id = key.toId();
        Stream memory s = streamOf[id][stream];
        if (s.owner == address(0)) return 0;

        uint32 elapsed = _elapsed(s);
        if (elapsed <= s.periodsDone) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        return _spendFor(s, elapsed, sqrtPriceX96);
    }

    /// @dev The buy a stream owes, given the periods elapsed and a price to value its holding at.
    function _spendFor(Stream memory s, uint32 elapsed, uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 target = uint256(s.targetPerPeriod) * elapsed;
        uint256 holding = _valueOf(s.acquired, s.zeroForOne, sqrtPriceX96);
        if (holding >= target) return 0;

        uint256 spend = target - holding;
        return spend > s.remaining ? s.remaining : spend;
    }

    /**
     * @notice What `amount` of the acquired currency is worth in the spent currency, at `sqrtPriceX96`.
     * @dev Done in two halves so the square of the price never has to exist: squaring a uint160 overflows, and the
     * usual workaround of shifting first throws away the precision the whole valuation depends on.
     */
    function _valueOf(uint256 amount, bool zeroForOne, uint160 sqrtPriceX96) private pure returns (uint256) {
        if (amount == 0) return 0;
        return zeroForOne
            // Holding currency1, valued in currency0: divide by the price twice.
            ? FullMath.mulDiv(FullMath.mulDiv(amount, Q96, sqrtPriceX96), Q96, sqrtPriceX96)
            // Holding currency0, valued in currency1: multiply by the price twice.
            : FullMath.mulDiv(FullMath.mulDiv(amount, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }

    /// @dev One stream's share of a batch: the index, what it spends, and the periods it catches up on.
    struct Due {
        uint256 index;
        uint256 spend;
        uint32 elapsed;
    }

    /// @dev One scan's worth of work: the streams due in each direction, and what each direction spends in total.
    struct Batch {
        Due[] zero;
        uint256 zeroLen;
        uint256 total0;
        Due[] one;
        uint256 oneLen;
        uint256 total1;
    }

    /**
     * @dev Settles up to {MAX_PER_SWAP} due streams, in one batched trade per direction.
     *
     * Every stream in a batch is priced before any of them trades, so two streams due in the same block get the same
     * price rather than one paying for the other's impact. The proceeds are then split by what each put in, which is
     * the only division that has that property.
     */
    function _settle(PoolKey memory key) private {
        if (_settling) return;

        PoolId id = key.toId();
        uint256 count = streamCount[id];
        if (count == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        Batch memory batch = _collect(id, count, sqrtPriceX96);

        if (batch.total0 > 0) _execute(key, id, true, batch.total0, batch.zero, batch.zeroLen);
        if (batch.total1 > 0) _execute(key, id, false, batch.total1, batch.one, batch.oneLen);
    }

    /**
     * @dev Walks the pool's streams from wherever the last scan stopped and gathers what is due.
     *
     * The cursor is what keeps this fair. Scanning from index zero every time would settle the oldest streams over
     * and over and leave a long list's tail permanently unreached, which is worse than being slow: it is a schedule
     * that silently depends on when you joined.
     */
    function _collect(PoolId id, uint256 count, uint160 sqrtPriceX96) private returns (Batch memory batch) {
        batch.zero = new Due[](MAX_PER_SWAP);
        batch.one = new Due[](MAX_PER_SWAP);

        uint256 at = _cursor[id];
        uint256 scanned;
        while (scanned < count && batch.zeroLen + batch.oneLen < MAX_PER_SWAP) {
            uint256 index = at % count;
            at++;
            scanned++;

            Stream memory s = streamOf[id][index];
            if (s.owner == address(0)) continue;

            uint32 elapsed = _elapsed(s);
            if (elapsed <= s.periodsDone) continue;

            uint256 spend = _spendFor(s, elapsed, sqrtPriceX96);
            if (spend == 0) {
                // Ahead of target: the period is settled without a trade, which is the strategy, not a skip.
                streamOf[id][index].periodsDone = elapsed;
                continue;
            }

            if (s.zeroForOne) {
                batch.zero[batch.zeroLen++] = Due(index, spend, elapsed);
                batch.total0 += spend;
            } else {
                batch.one[batch.oneLen++] = Due(index, spend, elapsed);
                batch.total1 += spend;
            }
        }
        _cursor[id] = at;
    }

    /// @dev Trades one direction's batch and splits the proceeds by what each stream put in.
    function _execute(PoolKey memory key, PoolId id, bool zeroForOne, uint256 total, Due[] memory due, uint256 len)
        private
    {
        (uint256 spent, uint256 received) = _swapAndSettle(key, zeroForOne, total);
        if (spent == 0) return;

        uint256 distributed;
        for (uint256 i = 0; i < len; i++) {
            Due memory d = due[i];
            Stream storage s = streamOf[id][d.index];

            // A partial fill is shared in the same proportion as a full one, so nobody is filled ahead of anybody.
            uint256 share = FullMath.mulDiv(d.spend, spent, total);
            uint256 out = i == len - 1 ? received - distributed : FullMath.mulDiv(d.spend, received, total);
            distributed += out;

            s.remaining -= share.toUint128();
            s.acquired += out.toUint128();
            s.periodsDone = d.elapsed;

            emit Executed(id, d.index, share, out, d.elapsed);
        }
    }

    /**
     * @dev Runs the batch through the pool and settles both sides.
     *
     * The reentrancy flag is what stops this recursing: the swap re-enters this hook's own `beforeSwap`, and without
     * the flag that would try to settle the same streams again inside their own settlement.
     */
    function _swapAndSettle(PoolKey memory key, bool zeroForOne, uint256 amount)
        private
        returns (uint256 spent, uint256 received)
    {
        Currency spend = zeroForOne ? key.currency0 : key.currency1;
        Currency acquire = zeroForOne ? key.currency1 : key.currency0;

        _settling = true;
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settling = false;

        int128 spendDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 acquireDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (spendDelta >= 0 || acquireDelta <= 0) return (0, 0);

        spent = int256(-spendDelta).toUint256();
        received = int256(acquireDelta).toUint256();

        poolManager.sync(spend);
        IERC20(Currency.unwrap(spend)).safeTransfer(address(poolManager), spent);
        poolManager.settle();
        poolManager.mint(address(this), acquire.toId(), received);
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Two operations share one callback because a hook only gets one. The discriminator is explicit rather than
     * inferred from the payload's shape, which would break the first time the two shapes coincided.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();

        if (abi.decode(data[:32], (Op)) == Op.Poke) {
            (, PoolKey memory key) = abi.decode(data, (Op, PoolKey));
            _settle(key);
            return "";
        }

        (, Currency currency, address to, uint256 amount) = abi.decode(data, (Op, Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    /**
     * @dev Settles due streams before somebody else's swap.
     *
     * Before rather than after, because a stream that trades first is a stream priced by the pool as the swapper
     * found it, and one that trades afterwards is priced by whatever the swapper just did to it.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _settle(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
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

    function hookName() external pure override returns (string memory) {
        return "StreamDCA";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "stream-dca.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "order-types";
        tags[1] = "dca";
        tags[2] = "value-averaging";
        tags[3] = "keeper-free";
        tags[4] = "no-admin";
    }
}
