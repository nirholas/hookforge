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
 * @title TradingCalendarHook
 * @notice Gives a pool a trading session, and closes it by raising the price of immediacy rather than by reverting.
 *
 * @dev Some assets should not be quoted around the clock at the same spread. A pool whose reference market is open
 * for part of the day is being priced blind the rest of the time, and the liquidity sitting in it overnight is
 * providing a free option to anyone with better information about where the asset will open.
 *
 * The obvious hook for this reverts outside session hours, and several published ones do exactly that. Reverting is
 * the wrong instrument. A pool that reverts is a pool that every router, aggregator and quoting service must special
 * case; it fails after the user has signed; it strands liquidity providers who wanted to exit; and it converts a
 * pricing problem into a liveness problem. Worse, it does not stop informed flow at all, it just moves it to the
 * first second after the open, where it hits the same liquidity at the same stale price.
 *
 * This hook keeps the pool open and quotable at every instant and expresses the session in the fee instead:
 *
 *   - Inside the session, swaps pay `sessionFee`.
 *   - Outside it, swaps pay `closedFee`, which is meant to be punitive rather than prohibitive.
 *   - Across `rampSeconds` on either side of each boundary the fee moves linearly between the two, so the open and
 *     the close are gradients rather than cliffs and there is no single block worth racing to.
 *
 * The ramp is the part that matters. A cliff at the open creates a race: the first swap after the boundary captures
 * the whole overnight gap at the session spread. A ramp means the trader who wants that gap must choose between
 * paying for it early and waiting for a lower fee while the price moves against them, which is precisely the tradeoff
 * that makes the gap get closed gradually and by more than one participant.
 *
 * Sessions are expressed in UTC seconds-of-day and may wrap midnight (`open > close` describes an overnight session).
 * `daysMask` selects the days of the week the session runs, bit 0 being Monday. A pool with `daysMask` covering all
 * seven days and a 24-hour session is always in session, which is a valid way to disable the calendar.
 *
 * Prior art: "New York Trading Hours" and "Trading Hours" hooks revert outside a window. Continuous fee ramps around
 * scheduled events appear in the `UniCast` design for known catalysts. Expressing a *recurring weekly calendar* as a
 * continuous fee surface, with no revert path and no oracle, is the contribution here.
 *
 * @custom:slug trading-calendar
 * @custom:family Time
 * @custom:prior-art The published calendar hooks ("New York Trading Hours", "Trading Hours") revert outside a window. Continuous fee ramps around a single scheduled event appear in the UniCast design. Expressing a recurring weekly calendar as a continuous fee surface, with no revert path and no oracle, is the contribution here.
 * @custom:limitation The calendar is a fixed weekly pattern in UTC. It does not know about holidays, half days, or daylight-saving shifts in the reference market, so a pool tracking an asset with an irregular schedule has to pick a session that is correct most weeks and accept that it is wrong on the exceptions.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract TradingCalendarHook is ForgeFeeHook, PoolConfigurable {
    /// @notice Seconds in a day.
    uint32 internal constant DAY = 86_400;

    /// @dev 1970-01-01 was a Thursday, which is index 3 in a Monday-first week.
    uint256 internal constant EPOCH_WEEKDAY_OFFSET = 3;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Session open, in seconds after UTC midnight. Must be < 86400.
        uint32 openSecond;
        /// @notice Session close, in seconds after UTC midnight. Must be < 86400. May be less than `openSecond`.
        uint32 closeSecond;
        /// @notice Length of the linear ramp on each side of a boundary, in seconds.
        uint32 rampSeconds;
        /// @notice Fee charged in the middle of the session, in hundredths of a bip.
        uint24 sessionFee;
        /// @notice Fee charged when the session is fully closed, in hundredths of a bip.
        uint24 closedFee;
        /// @notice Days the session runs; bit 0 is Monday, bit 6 is Sunday. Must be non-zero.
        uint8 daysMask;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @dev A seconds-of-day field was at or above 86400.
    error InvalidSecondOfDay();

    /// @dev `daysMask` selected no days, which would close the pool permanently.
    error NoTradingDays();

    /// @dev `closedFee` must be at least `sessionFee`; a session that is cheaper when closed is a configuration error.
    error ClosedFeeBelowSessionFee();

    /// @dev The ramp cannot be longer than the session or the gap between sessions it has to fit inside.
    error RampTooLong();

    /// @notice Emitted once per pool, when its calendar is fixed.
    event PoolConfigured(
        PoolId indexed id,
        uint32 openSecond,
        uint32 closeSecond,
        uint32 rampSeconds,
        uint24 sessionFee,
        uint24 closedFee,
        uint8 daysMask
    );

    /// @notice Emitted on every swap with the fee the calendar produced.
    event SessionPriced(PoolId indexed id, uint24 fee, bool inSession);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix the calendar for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.openSecond >= DAY || cfg.closeSecond >= DAY) revert InvalidSecondOfDay();
        if (cfg.daysMask == 0 || cfg.daysMask > 0x7F) revert NoTradingDays();
        if (cfg.closedFee < cfg.sessionFee) revert ClosedFeeBelowSessionFee();
        FeeMath.requireValid(cfg.closedFee);
        // Both ramps must fit inside the shorter of the session and the break, or the fee surface would be
        // discontinuous at a boundary and the "no cliff" property this hook exists for would not hold.
        uint32 sessionLength = cfg.openSecond <= cfg.closeSecond
            ? cfg.closeSecond - cfg.openSecond
            : DAY - cfg.openSecond + cfg.closeSecond;
        uint32 breakLength = DAY - sessionLength;
        if (sessionLength != 0 && (uint256(cfg.rampSeconds) * 2 > sessionLength || uint256(cfg.rampSeconds) * 2 > breakLength)) {
            revert RampTooLong();
        }

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(
            id, cfg.openSecond, cfg.closeSecond, cfg.rampSeconds, cfg.sessionFee, cfg.closedFee, cfg.daysMask
        );
    }

    /// @notice Whether `timestamp` falls on a day this pool's calendar trades.
    function isTradingDay(PoolId id, uint256 timestamp) public view returns (bool) {
        uint256 weekday = (timestamp / DAY + EPOCH_WEEKDAY_OFFSET) % 7;
        return (configOf[id].daysMask >> weekday) & 1 == 1;
    }

    /**
     * @notice The fee this pool's calendar produces at `timestamp`, and whether the session is fully open.
     * @dev Pure function of the configuration and the clock, so an off-chain quoter can reproduce it exactly.
     */
    function feeAt(PoolId id, uint256 timestamp) public view returns (uint24 fee, bool inSession) {
        Config memory cfg = configOf[id];
        if (!isTradingDay(id, timestamp)) return (cfg.closedFee, false);

        // casting to 'uint32' is safe because `timestamp % DAY` is strictly less than DAY (86_400).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 sod = uint32(timestamp % DAY);
        uint32 sinceOpen = _forwardDistance(cfg.openSecond, sod);
        uint32 untilClose = _forwardDistance(sod, cfg.closeSecond);

        uint32 sessionLength = _forwardDistance(cfg.openSecond, cfg.closeSecond);
        inSession = sinceOpen < sessionLength;

        uint24 spread = cfg.closedFee - cfg.sessionFee;
        if (cfg.rampSeconds == 0) return (inSession ? cfg.sessionFee : cfg.closedFee, inSession);

        if (inSession) {
            // Inside the session the fee is `sessionFee`, rising back toward `closedFee` over the last `rampSeconds`.
            if (untilClose >= cfg.rampSeconds) return (cfg.sessionFee, true);
            uint256 progressed = cfg.rampSeconds - untilClose;
            // `mulDiv(spread, progressed, rampSeconds)` is at most `spread`, a uint24, because `progressed < rampSeconds`.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (cfg.sessionFee + uint24(FeeMath.mulDiv(spread, progressed, cfg.rampSeconds)), true);
        }

        // Outside the session the fee is `closedFee`, falling toward `sessionFee` over the last `rampSeconds`
        // before the open.
        uint32 untilOpen = _forwardDistance(sod, cfg.openSecond);
        if (untilOpen >= cfg.rampSeconds) return (cfg.closedFee, false);
        uint256 remaining = untilOpen;
        // Bounded by `spread` for the same reason as the in-session branch: `remaining < rampSeconds`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (cfg.sessionFee + uint24(FeeMath.mulDiv(spread, remaining, cfg.rampSeconds)), false);
    }

    /// @notice The fee this pool would charge a swap landing right now.
    function quoteFee(PoolId id) external view returns (uint24 fee) {
        (fee,) = feeAt(id, block.timestamp);
    }

    /// @dev Seconds from `from` to `to` on a circular day.
    function _forwardDistance(uint32 from, uint32 to) private pure returns (uint32) {
        return to >= from ? to - from : DAY - from + to;
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].daysMask == 0) revert PoolNotConfigured();
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        (uint24 fee, bool inSession) = feeAt(id, block.timestamp);
        emit SessionPriced(id, fee, inSession);
        return fee;
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "TradingCalendar";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "trading-calendar.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "dynamic-fee";
        tags[1] = "schedule";
        tags[2] = "rwa";
        tags[3] = "oracle-free";
    }
}
