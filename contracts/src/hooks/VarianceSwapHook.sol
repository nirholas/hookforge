// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeHook} from "../base/ForgeHook.sol";

/**
 * @title VarianceSwapHook
 * @notice Turns the exposure a liquidity provider already has into something they can actually sell.
 *
 * @dev Everybody who has provided liquidity to an automated market maker is short volatility. It is not a choice they
 * made and in most cases not one they were told about: the position loses to whoever rebalances against it, in
 * proportion to how much the price moves, which is the payoff of a short variance position with extra steps. The
 * literature calls it loss-versus-rebalancing, and the practical consequence is that a provider's real risk has no
 * name in the interface and no way to hedge.
 *
 * The exposure exists. What is missing is the other side of it. This hook measures the pool's realised variance from
 * its own ticks, and lets anybody take either end: deposit collateral to be short variance and collect premiums, or
 * pay a premium to be long it and get paid if the pool turns out to be wilder than the strike said. A provider who
 * wants to stop being short volatility can buy exactly enough of the long side to cancel it, in the same contract,
 * denominated in the same units, against the same pool.
 *
 * The variance is the pool's own. It is the sum of squared tick moves the pool actually made, divided by the seconds
 * it took, and it is not quoted by anybody, not signed by anybody, and not available to be reported wrongly. Ticks
 * are log prices, which is exactly what a variance calculation wants, so the pool's own data structure happens to be
 * the correct input with no conversion at all.
 *
 * Every note is fully collateralised when it is written. The most it can ever pay is locked at that moment and
 * released when it settles, so the short side cannot be surprised and the long side cannot be defaulted on. That is a
 * real constraint on how much can be written and it is the right one: an uncollateralised variance seller is a
 * counterparty risk wearing a payoff diagram.
 *
 * @custom:slug variance-swap
 * @custom:family Derivatives
 * @custom:prior-art Variance swaps are standard over-the-counter equity derivatives. On-chain, Squeeth and this catalogue's own PowerPerp give quadratic price exposure, and Opyn, Volmex and Panoptic build volatility products on option or index machinery, all needing an external mark. Loss-versus-rebalancing is well described in the literature and universally left unhedged. Measuring realised variance from a pool's own ticks and settling fully collateralised notes on it inside that same pool, so the exposure and its hedge live in one contract, is the contribution here.
 * @custom:limitation Realised variance is sampled per swap, so a pool that trades rarely reports a variance built from few observations and a pool that is quiet between two distant prints understates the path between them. The measure also cannot tell a real move from a manipulated one; on a shallow pool, buying a note and then pushing the price around is a strategy, and the cap on payout is the only thing bounding it. Notes settle in one collateral currency and pay nothing before expiry, so this is a held-to-maturity instrument, not a tradeable one. And the strike is chosen by whoever writes the note rather than discovered, so a badly struck note is simply a bad trade.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract VarianceSwapHook is ForgeHook, ERC20 {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Shares permanently burned on the first deposit, against the usual donation front-run.
    uint256 internal constant MINIMUM_SHARES = 1_000;

    /// @notice A long-variance position, fully collateralised by the vault when it was written.
    struct Note {
        /// @notice Who holds it and is paid at expiry.
        address holder;
        /// @notice The size the payout scales with, in collateral units.
        uint128 notional;
        /// @notice The most this note can ever pay. Locked in the vault for its whole life.
        uint128 maxPayout;
        /// @notice The pool's cumulative variance when the note was written.
        uint256 cumulativeAtOpen;
        /// @notice When it was written.
        uint64 openedAt;
        /// @notice When it may be settled.
        uint64 expiresAt;
    }

    /// @notice The currency premiums are paid in and payouts are made in. The pool's second currency.
    Currency public collateral;

    /// @notice The pool this hook serves, bound at its first initialization.
    PoolKey public poolKey;

    /**
     * @notice The variance a note is priced against, in squared ticks per second.
     * @dev Squared ticks is the pool's own unit and needs no conversion: a tick is a fixed multiplicative step, so a
     * squared tick move is a squared log return, which is what variance is defined on.
     */
    uint256 public immutable strikePerSecond;

    /// @notice The variance at which a note pays its whole notional. Anything above this is not paid for.
    uint256 public immutable capPerSecond;

    /// @notice The shortest and longest a note may run for, in seconds.
    uint64 public immutable minTerm;

    /// @notice As {minTerm}.
    uint64 public immutable maxTerm;

    /// @notice Sum of squared tick moves the pool has made, in squared ticks.
    uint256 public cumulativeVariance;

    /// @notice The tick at the last observation. Squared moves are measured from here.
    int24 public lastTick;

    /// @notice Collateral the vault holds in total, including what is locked against live notes.
    uint256 public totalCollateral;

    /// @notice Collateral locked against live notes and unavailable to withdraw.
    uint256 public totalLocked;

    /// @notice Notes by index.
    mapping(uint256 => Note) public noteOf;

    /// @notice How many notes have ever been written.
    uint256 public noteCount;

    /// @dev A strike at or above the cap leaves no room for the note to pay anything.
    error InvalidStrike();

    /// @dev The term bounds are the wrong way round, or a term of zero was allowed.
    error InvalidTerm();

    /// @dev This hook serves one pool, bound the first time one initializes with it.
    error AlreadyBound();

    /// @dev The requested term is outside what this hook writes.
    error TermOutOfRange(uint64 shortest, uint64 longest);

    /// @dev The vault does not have enough free collateral to back this note.
    error InsufficientCollateral(uint256 free, uint256 needed);

    /// @dev The deposit or withdrawal was too small to move any shares.
    error AmountTooSmall();

    /// @dev The first deposit must exceed the permanently locked minimum.
    error InsufficientInitialLiquidity();

    /// @dev Withdrawing this much would leave live notes uncollateralised.
    error CollateralLocked(uint256 free);

    /// @dev There is no note at that index, or it has already settled.
    error NoSuchNote();

    /// @dev The note has not reached its expiry.
    error NotExpired(uint64 expiresAt);

    /// @notice Emitted when somebody takes the short side by depositing collateral.
    event Deposited(address indexed who, uint256 amount, uint256 shares);

    /// @notice Emitted when somebody takes their collateral back out.
    event Withdrawn(address indexed who, uint256 amount, uint256 shares);

    /// @notice Emitted when a long-variance note is written.
    event Opened(uint256 indexed note, address indexed holder, uint256 notional, uint256 premium, uint256 maxPayout);

    /// @notice Emitted when a note expires and is paid, with the squared tick movement it was judged on.
    event Settled(uint256 indexed note, address indexed holder, uint256 realised, uint256 payout);

    constructor(
        IPoolManager _poolManager,
        uint256 _strikePerSecond,
        uint256 _capPerSecond,
        uint64 _minTerm,
        uint64 _maxTerm,
        string memory shareName,
        string memory shareSymbol
    ) ForgeHook(_poolManager) ERC20(shareName, shareSymbol) {
        if (_strikePerSecond == 0 || _strikePerSecond >= _capPerSecond) revert InvalidStrike();
        if (_minTerm == 0 || _maxTerm < _minTerm) revert InvalidTerm();

        strikePerSecond = _strikePerSecond;
        capPerSecond = _capPerSecond;
        minTerm = _minTerm;
        maxTerm = _maxTerm;
    }

    /// @notice Collateral not locked against a live note, and therefore available to back a new one or be withdrawn.
    function freeCollateral() public view returns (uint256) {
        return totalCollateral - totalLocked;
    }

    /// @notice Total squared tick movement the pool has made since `cumulativeAtOpen`.
    function realisedSince(uint256 cumulativeAtOpen) public view returns (uint256) {
        return cumulativeVariance <= cumulativeAtOpen ? 0 : cumulativeVariance - cumulativeAtOpen;
    }

    /**
     * @notice What a note of `notional` costs, and the most it could pay.
     *
     * @dev The notional IS the maximum payout, and the premium is the fraction of it the strike implies. Pricing it
     * this way rather than as a rate on a rate keeps every quantity in the contract a plain token amount, which is
     * what makes the collateral requirement legible: writing a note of a hundred locks a hundred.
     *
     * The term does not appear, and that is not an omission. A note pays on the average variance rate over its life
     * against the cap rate, so a longer note covers proportionally more total variance and is worth the same. What a
     * longer term buys is a better-sampled average, not a bigger bet.
     */
    function quote(uint256 notional) public view returns (uint256 premium, uint256 maxPayout) {
        premium = (notional * strikePerSecond) / capPerSecond;
        maxPayout = notional;
    }

    /// @notice What a live note would pay if it settled now, ignoring its expiry.
    function payoutIfSettledNow(uint256 note) public view returns (uint256) {
        Note memory n = noteOf[note];
        if (n.holder == address(0)) return 0;
        return _payout(n);
    }

    /**
     * @dev The payout for a note: its notional, scaled by how much of the capped variance actually happened.
     *
     * The denominator is the variance the note was written to cover over its whole term, so a note pays its full
     * notional exactly when the pool was as wild as the cap allowed for, and proportionally less otherwise.
     */
    function _payout(Note memory n) private view returns (uint256) {
        uint256 term = uint256(n.expiresAt) - n.openedAt;
        uint256 capTotal = capPerSecond * term;
        if (capTotal == 0) return 0;

        uint256 realised = realisedSince(n.cumulativeAtOpen);
        if (realised >= capTotal) return n.maxPayout;
        return (uint256(n.maxPayout) * realised) / capTotal;
    }

    /// @notice Take the short side: deposit collateral, earn premiums, wear the payouts.
    function deposit(uint256 amount) external returns (uint256 shares) {
        if (amount == 0) revert AmountTooSmall();
        IERC20(Currency.unwrap(collateral)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 supply = totalSupply();
        if (supply == 0) {
            if (amount <= MINIMUM_SHARES) revert InsufficientInitialLiquidity();
            _mint(address(this), MINIMUM_SHARES);
            shares = amount - MINIMUM_SHARES;
        } else {
            shares = (amount * supply) / totalCollateral;
        }
        if (shares == 0) revert AmountTooSmall();

        totalCollateral += amount;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amount, shares);
    }

    /**
     * @notice Take collateral back out.
     * @dev Only what is not locked against a live note may leave. A short seller is committed for as long as the
     * notes they are backing, which is the whole point of writing them collateralised.
     */
    function withdraw(uint256 shares) external returns (uint256 amount) {
        if (shares == 0) revert AmountTooSmall();

        uint256 supply = totalSupply();
        amount = (totalCollateral * shares) / supply;
        if (amount == 0) revert AmountTooSmall();

        uint256 free = freeCollateral();
        if (amount > free) revert CollateralLocked(free);

        _burn(msg.sender, shares);
        totalCollateral -= amount;
        IERC20(Currency.unwrap(collateral)).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, shares);
    }

    /**
     * @notice Take the long side: pay a premium now, get paid if the pool is wilder than the strike.
     * @dev The maximum payout is locked out of the vault for the note's whole life, so this can only be written while
     * somebody is actually short enough to cover it.
     */
    function open(uint256 notional, uint64 term) external returns (uint256 note) {
        if (term < minTerm || term > maxTerm) revert TermOutOfRange(minTerm, maxTerm);
        if (notional == 0) revert AmountTooSmall();

        (uint256 premium, uint256 maxPayout) = quote(notional);
        if (maxPayout == 0 || premium == 0) revert AmountTooSmall();

        uint256 free = freeCollateral();
        // The premium arrives with the note, so it counts toward covering the note it is paying for.
        if (maxPayout > free + premium) revert InsufficientCollateral(free, maxPayout);

        IERC20(Currency.unwrap(collateral)).safeTransferFrom(msg.sender, address(this), premium);
        totalCollateral += premium;
        totalLocked += maxPayout;

        note = noteCount++;
        noteOf[note] = Note({
            holder: msg.sender,
            notional: notional.toUint128(),
            maxPayout: maxPayout.toUint128(),
            cumulativeAtOpen: cumulativeVariance,
            openedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + term
        });

        emit Opened(note, msg.sender, notional, premium, maxPayout);
    }

    /**
     * @notice Settle an expired note, paying its holder what the pool actually did.
     * @dev Permissionless, because the money is owed to a named account either way and there is nothing to decide.
     */
    function settle(uint256 note) external {
        Note memory n = noteOf[note];
        if (n.holder == address(0)) revert NoSuchNote();
        // The expiry is minutes or longer, so the seconds a proposer controls cannot move the outcome meaningfully.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < n.expiresAt) revert NotExpired(n.expiresAt);

        uint256 payout = _payout(n);
        uint256 realised = realisedSince(n.cumulativeAtOpen);

        delete noteOf[note];
        totalLocked -= n.maxPayout;

        if (payout > 0) {
            totalCollateral -= payout;
            IERC20(Currency.unwrap(collateral)).safeTransfer(n.holder, payout);
        }
        emit Settled(note, n.holder, realised, payout);
    }

    /// @dev Binds the hook to the first pool that initializes with it and starts the variance clock.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        if (address(poolKey.hooks) != address(0)) revert AlreadyBound();
        poolKey = key;
        collateral = key.currency1;
        lastTick = tick;
        return this.afterInitialize.selector;
    }

    /**
     * @dev Adds the square of the move the last swap made.
     *
     * Sampled before the swap rather than after, so the move recorded is one the pool has finished making. Reading it
     * afterwards would attribute the current swap's move to itself and then attribute it again next time.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (, int24 tick,,) = poolManager.getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        int256 moved = int256(tick) - int256(lastTick);
        if (moved != 0) {
            uint256 magnitude = (moved < 0 ? -moved : moved).toUint256();
            cumulativeVariance += magnitude * magnitude;
            lastTick = tick;
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
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
        return "VarianceSwap";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "variance-swap.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "derivatives";
        tags[1] = "volatility";
        tags[2] = "variance-swap";
        tags[3] = "oracle-free";
        tags[4] = "no-admin";
    }
}
