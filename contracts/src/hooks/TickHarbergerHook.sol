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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseHookFee} from "uniswap-hooks/fee/BaseHookFee.sol";

import {ForgeMetadata} from "../base/ForgeMetadata.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title TickHarbergerHook
 * @notice Leases the right to price a pool's flow, one tick range at a time, under a Harberger tax.
 *
 * @dev An automated market maker charges the same fee everywhere, which is the same as saying it believes every price
 * level is equally valuable to trade at. No venue with a human on it believes that. The flow near the current price
 * is worth something quite different from the flow forty percent away, and it changes hour by hour, and a governance
 * vote on a single pool-wide number is not a mechanism for discovering it.
 *
 * Auction-managed AMMs answered this by selling the right to set the fee for the whole pool, which is a real
 * improvement and still one number. This sells it per tick range. Somebody who believes the band the price is sitting
 * in is worth more than the market thinks can buy exactly that band, and nothing else.
 *
 * The lease is Harberger. A holder names their own price for the range and pays continuous rent on that number, and
 * anybody may take the range from them at any moment by paying it. Naming a low price is cheap and loses the range;
 * naming a high one keeps it and costs. There is no auction to run, no round to wait for, and nobody who decides who
 * wins: the holder's own valuation is both the tax base and the strike, which is what makes the two honest at once.
 *
 * Rent accrues only while a range holds the current price, which is the only time the right is worth anything. That
 * is not a concession, it is what makes squatting self-defeating: holding a distant range costs nothing, and the
 * valuation that makes it free to hold is also the price at which it is taken away the moment it becomes valuable.
 *
 * Rent goes to the pool's liquidity providers by donation, so the people whose capital is being priced are the people
 * paid for it. What the leaseholder earns is the fee they set, taken on top of the pool's own, which is the position
 * they paid rent to occupy.
 *
 * @custom:slug tick-harberger
 * @custom:family Fees and MEV
 * @custom:prior-art The am-AMM line of work (Adams, Milionis, Moallemi, Roughgarden) auctions the right to manage a whole pool, and v4 hooks implementing it exist. Harberger taxes on-chain go back to Radical Markets and appear in Wildcards, This Artwork Is Always On Sale and the partial-common-ownership NFT designs. Dynamic-fee hooks set one fee per pool from volatility or flow. Leasing the fee-setting right per tick range under a continuous self-assessed tax, so that price levels are priced separately and by whoever thinks they know better, is the contribution here.
 * @custom:limitation Rent only accrues where the price actually is, so a pool that never moves pays rent on one range and leaves the rest free to hold. That is the intended incentive and it does mean the mechanism says nothing about ranges the price never visits. The lease is denominated in the pool's second currency, which must be an ERC-20, so a pool of native currency against nothing else cannot use it. Rent reaches providers through `donate`, which credits whoever is in range when it settles rather than whoever was in range while it accrued; settling often keeps that close, and `settleRent` is callable by anyone for exactly that reason. Finally, a leaseholder charging the maximum is still charging it, so `maxFeePips` is the real protection for traders and a pool that sets it carelessly has sold them.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract TickHarbergerHook is BaseHookFee, ForgeMetadata, PoolConfigurable, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Per-pool terms, fixed before the pool exists.
    struct Config {
        /// @notice Width of one leasable range, in ticks. A multiple of the pool's tick spacing.
        int24 rangeWidth;
        /// @notice Rent per day, in basis points of the holder's own valuation.
        uint32 rentRateBps;
        /// @notice The most a leaseholder may charge, in hundredths of a bip. The traders' protection.
        uint24 maxFeePips;
        /// @notice The smallest deposit a lease may be opened with, so a lease always has some runway.
        uint128 minDeposit;
    }

    /// @notice A standing lease on one range.
    struct Lease {
        /// @notice Who holds it. Zero means the range is unleased and the hook takes nothing.
        address holder;
        /// @notice The fee they charge on swaps in this range, in hundredths of a bip.
        uint24 feePips;
        /// @notice What they say the range is worth. Both the rent base and the price anybody may take it at.
        uint128 valuation;
        /// @notice Rent not yet spent. When it runs out the lease lapses.
        uint128 deposit;
        /// @notice When this range last became the one holding the price. Zero when it is not the active range.
        uint64 activeSince;
    }

    /// @notice Terms for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The standing lease on each range of each pool.
    mapping(PoolId => mapping(int256 => Lease)) public leaseOf;

    /// @notice The range currently holding each pool's price.
    mapping(PoolId => int256) public activeRange;

    /// @dev Whether {activeRange} has ever been set, since range zero is a real range.
    mapping(PoolId => bool) private _activeKnown;

    /// @notice Rent collected and not yet donated to the pool's providers, in currency1.
    mapping(PoolId => uint256) public pendingRent;

    /// @notice Fee proceeds owed to a leaseholder, per currency, held as claims until they withdraw.
    mapping(address => mapping(Currency => uint256)) public owed;

    /// @dev The range that held the price when the current swap began. Read by the fee, which runs after the swap.
    int256 private _swapRange;

    /// @dev The pool the current swap belongs to, so a stale `_swapRange` can never be applied to another pool.
    PoolId private _swapPool;

    /// @dev Operations the unlock callback can be asked to perform.
    enum Op {
        Donate,
        Withdraw
    }

    /// @dev A range narrower than the tick spacing, or not a whole number of them, cannot be a range.
    error InvalidRangeWidth();

    /// @dev A rent of zero is not a Harberger tax, and one above the whole valuation per day is confiscation.
    error InvalidRentRate();

    /// @dev The ceiling on a leaseholder's fee must itself be below the protocol maximum.
    error InvalidMaxFee();

    /// @dev The fee asked for is above what this pool allows a leaseholder to charge.
    error FeeTooHigh(uint24 maximum);

    /// @dev The deposit is below the pool's minimum, which would leave the lease with no runway.
    error DepositTooSmall(uint128 minimum);

    /// @dev A valuation of zero would make the lease free to take and free to hold, which is not a lease.
    error InvalidValuation();

    /// @dev Only the `PoolManager` may drive the unlock callback. Named distinctly because `BaseHook` declares its own.
    error CallbackNotPoolManager();

    /// @dev There is nothing to settle or withdraw.
    error NothingToDo();

    /// @notice Emitted when a range changes hands, with the price paid to the outgoing holder.
    event Leased(
        PoolId indexed id, int256 indexed range, address indexed holder, uint128 valuation, uint24 feePips, uint256 paid
    );

    /// @notice Emitted when rent is charged against a lease's deposit.
    event RentCharged(PoolId indexed id, int256 indexed range, uint256 amount, uint128 depositLeft);

    /// @notice Emitted when a lease runs out of deposit and the range falls vacant.
    event Lapsed(PoolId indexed id, int256 indexed range, address indexed holder);

    /// @notice Emitted when collected rent is donated to the pool's liquidity providers.
    event RentSettled(PoolId indexed id, uint256 amount);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Fix a pool's terms before it exists. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.rangeWidth <= 0 || cfg.rangeWidth % key.tickSpacing != 0) revert InvalidRangeWidth();
        if (cfg.rentRateBps == 0 || cfg.rentRateBps > BPS) revert InvalidRentRate();
        if (cfg.maxFeePips == 0 || cfg.maxFeePips > MAX_HOOK_FEE / 10) revert InvalidMaxFee();

        _requireUninitialized(key);
        configOf[PoolId.wrap(keccak256(abi.encode(key)))] = cfg;
    }

    /// @notice The range index a tick falls in. Floor division, so the ranges tile the whole tick space evenly.
    function rangeOf(int24 tick, int24 width) public pure returns (int256) {
        int256 t = tick;
        int256 w = width;
        return t >= 0 ? t / w : -((-t + w - 1) / w);
    }

    /// @notice The range currently holding a pool's price.
    function currentRange(PoolKey calldata key) public view returns (int256) {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        return rangeOf(tick, configOf[id].rangeWidth);
    }

    /// @notice Rent a lease has accrued since it was last charged, whether or not it has been taken yet.
    function accruedRent(PoolKey calldata key, int256 range) public view returns (uint256) {
        PoolId id = key.toId();
        return _accruedRent(configOf[id], leaseOf[id][range]);
    }

    /// @dev Rent owed by a lease right now, capped at what its deposit can actually pay.
    function _accruedRent(Config memory cfg, Lease memory lease) private view returns (uint256) {
        if (lease.holder == address(0) || lease.activeSince == 0) return 0;
        uint256 elapsed = block.timestamp - lease.activeSince;
        uint256 rent = (uint256(lease.valuation) * cfg.rentRateBps * elapsed) / (BPS * 1 days);
        return rent > lease.deposit ? lease.deposit : rent;
    }

    /**
     * @notice Take a range, paying the current holder their own valuation for it.
     *
     * @dev The price is whatever the incumbent said the range was worth, which is the entire mechanism: they set it,
     * they pay rent on it, and they are bound by it. Their remaining deposit goes back to them along with the price,
     * since it is rent they prepaid and did not use.
     *
     * Claiming a range you already hold is how you revise your own valuation: you pay yourself the price and the old
     * deposit back, so the only money that moves is the difference in deposit.
     *
     * @param key The pool.
     * @param range The range index, from {rangeOf}.
     * @param valuation What you say the range is worth. Your rent base, and the price anyone may take it from you at.
     * @param feePips The fee you will charge on swaps in this range, in hundredths of a bip.
     * @param deposit Rent paid up front, in currency1. When it runs out the lease lapses.
     */
    function claim(PoolKey calldata key, int256 range, uint128 valuation, uint24 feePips, uint128 deposit) external {
        PoolId id = key.toId();
        Config memory cfg = configOf[id];
        if (cfg.rangeWidth == 0) revert PoolNotConfigured();
        if (valuation == 0) revert InvalidValuation();
        if (feePips > cfg.maxFeePips) revert FeeTooHigh(cfg.maxFeePips);
        if (deposit < cfg.minDeposit) revert DepositTooSmall(cfg.minDeposit);

        // Bring the incumbent's rent up to date first, so the deposit they are refunded is what they actually have
        // left rather than what they had when they last traded.
        _charge(id, cfg, range);

        Lease memory incumbent = leaseOf[id][range];
        uint256 price = incumbent.holder == address(0) ? 0 : incumbent.valuation;
        uint256 refund = incumbent.holder == address(0) ? 0 : price + incumbent.deposit;

        IERC20 rentToken = IERC20(Currency.unwrap(key.currency1));
        rentToken.safeTransferFrom(msg.sender, address(this), price + deposit);
        if (refund > 0) rentToken.safeTransfer(incumbent.holder, refund);

        bool isActive = _activeKnown[id] && activeRange[id] == range;
        leaseOf[id][range] = Lease({
            holder: msg.sender,
            feePips: feePips,
            valuation: valuation,
            deposit: deposit,
            activeSince: isActive ? uint64(block.timestamp) : 0
        });

        emit Leased(id, range, msg.sender, valuation, feePips, price);
    }

    /**
     * @dev Charges a lease the rent it has accrued, lapsing it if the deposit cannot cover it.
     *
     * Rent is added to the pool's pending pot rather than sent anywhere, because sending it means touching the
     * `PoolManager`, and this runs in the middle of swaps.
     */
    function _charge(PoolId id, Config memory cfg, int256 range) private {
        Lease storage lease = leaseOf[id][range];
        if (lease.holder == address(0) || lease.activeSince == 0) return;

        uint256 rent = _accruedRent(cfg, lease);
        if (rent == 0) {
            lease.activeSince = uint64(block.timestamp);
            return;
        }

        pendingRent[id] += rent;

        if (rent >= lease.deposit) {
            emit RentCharged(id, range, rent, 0);
            emit Lapsed(id, range, lease.holder);
            delete leaseOf[id][range];
            return;
        }

        // Casting is safe: `rent` was capped at the deposit, which is a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        lease.deposit -= uint128(rent);
        lease.activeSince = uint64(block.timestamp);
        emit RentCharged(id, range, rent, lease.deposit);
    }

    /**
     * @notice Donate a pool's collected rent to its liquidity providers. Callable by anyone.
     *
     * @dev Rent has to reach providers through the pool, and the pool credits whoever is in range at the moment of the
     * donation. Nobody is paid for calling this, which is deliberate: the people who want it called are the providers
     * it pays, and a bounty would only come out of the same money.
     */
    function settleRent(PoolKey calldata key) external {
        PoolId id = key.toId();
        Config memory cfg = configOf[id];
        if (cfg.rangeWidth == 0) revert PoolNotConfigured();

        // Charge the live lease first, so settling picks up rent owed right up to this moment.
        if (_activeKnown[id]) _charge(id, cfg, activeRange[id]);

        uint256 amount = pendingRent[id];
        if (amount == 0) revert NothingToDo();
        pendingRent[id] = 0;

        poolManager.unlock(abi.encode(Op.Donate, key, address(0), amount));
        emit RentSettled(id, amount);
    }

    /// @notice Withdraw fee proceeds a leaseholder has earned, as real tokens rather than claims.
    function withdraw(PoolKey calldata key) external {
        uint256 amount0 = owed[msg.sender][key.currency0];
        uint256 amount1 = owed[msg.sender][key.currency1];
        if (amount0 == 0 && amount1 == 0) revert NothingToDo();

        owed[msg.sender][key.currency0] = 0;
        owed[msg.sender][key.currency1] = 0;
        poolManager.unlock(abi.encode(Op.Withdraw, key, msg.sender, (amount1 << 128) | amount0));
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Two operations share one callback because a hook may only have one. The discriminator is explicit rather
     * than inferred from the shape of the payload, which would break the first time the two shapes coincided.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();
        (Op op, PoolKey memory key, address to, uint256 packed) = abi.decode(data, (Op, PoolKey, address, uint256));

        if (op == Op.Donate) {
            poolManager.donate(key, 0, packed, "");
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), packed);
            poolManager.settle();
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
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        if (cfg.rangeWidth == 0) revert PoolNotConfigured();

        activeRange[id] = rangeOf(tick, cfg.rangeWidth);
        _activeKnown[id] = true;
        return this.afterInitialize.selector;
    }

    /**
     * @dev Records which range held the price when this swap began.
     *
     * The fee runs after the swap, by which time the price has moved, and charging a swap the fee of the range it
     * ended in would let a large trade cross into a cheap range and pay its price for the whole journey.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (, int24 tick,,) = poolManager.getSlot0(id);
        _swapPool = id;
        _swapRange = rangeOf(tick, configOf[id].rangeWidth);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev The fee set by whoever leases the range the swap started in. An unleased range charges nothing.
    function _getHookFee(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        PoolId id = key.toId();
        if (PoolId.unwrap(_swapPool) != PoolId.unwrap(id)) return 0;

        Lease memory lease = leaseOf[id][_swapRange];
        if (lease.holder == address(0) || lease.deposit == 0) return 0;
        return lease.feePips;
    }

    /**
     * @dev Credits the fee to the leaseholder, charges their rent, and moves the lease that holds the price.
     *
     * The proceeds are measured as the change in the hook's own claims rather than recomputed from the fee, because
     * the base contract already did the arithmetic and rounding once and doing it twice invites the two to disagree.
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

        _credit(key, before0, before1);
        _rotate(key.toId());
        return (selector, hookDelta);
    }

    /// @dev What the hook holds of each of the pool's currencies, as ERC-6909 claims.
    function _held(PoolKey calldata key) private view returns (uint256 held0, uint256 held1) {
        held0 = poolManager.balanceOf(address(this), key.currency0.toId());
        held1 = poolManager.balanceOf(address(this), key.currency1.toId());
    }

    /// @dev Books whatever the swap just skimmed to whoever leases the range it started in.
    function _credit(PoolKey calldata key, uint256 before0, uint256 before1) private {
        PoolId id = key.toId();
        address holder = leaseOf[id][_swapRange].holder;
        if (holder == address(0)) return;

        (uint256 after0, uint256 after1) = _held(key);
        if (after0 > before0) owed[holder][key.currency0] += after0 - before0;
        if (after1 > before1) owed[holder][key.currency1] += after1 - before1;
    }

    /// @dev Charges the outgoing range's rent and starts the incoming range's clock.
    function _rotate(PoolId id) private {
        Config memory cfg = configOf[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 landed = rangeOf(tick, cfg.rangeWidth);

        // Charging the outgoing range also refreshes its clock, so a swap that stays put still pays for the time.
        _charge(id, cfg, activeRange[id]);

        if (landed != activeRange[id]) {
            activeRange[id] = landed;
            Lease storage arrival = leaseOf[id][landed];
            if (arrival.holder != address(0)) arrival.activeSince = uint64(block.timestamp);
        }
    }

    /**
     * @inheritdoc BaseHookFee
     * @dev Nothing to do. Proceeds are attributed to a leaseholder as they are taken and paid out by {withdraw},
     * which is the same claims turned into tokens for the one account entitled to them.
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
        return "TickHarberger";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "tick-harberger.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "fees";
        tags[1] = "harberger";
        tags[2] = "auction";
        tags[3] = "mev";
        tags[4] = "no-admin";
    }
}
