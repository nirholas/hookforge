// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title DutchClearingLaunchHook
 * @notice A descending-price launch enforced as a floor on what the pool will sell at, so a token opens at the price
 * the first real buyer is willing to pay rather than the price the deployer guessed.
 *
 * @dev A launch has to answer a question nobody can answer in advance: what is this worth. Fixed-price launches
 * answer it by guessing, and are wrong in one of two expensive directions. Guess low and the entire mispricing is
 * captured in the first block by whoever pays the most gas, which is the mechanism people call a snipe. Guess high
 * and nothing trades until the price falls, except that in an AMM the price only falls when somebody sells, so the
 * first honest buyer eats the whole descent.
 *
 * A Dutch auction answers it by asking. Start above any plausible value and come down until somebody accepts; the
 * clearing price is then discovered rather than declared, and the first buyer pays roughly what the marginal buyer
 * thinks it is worth instead of a number in a config file.
 *
 * The published way to put a Dutch auction on an AMM is a liquidity bootstrapping pool, which ramps the pool's
 * weights so the quoted price drifts down on its own. That works and it needs a weighted pool, a weight schedule and
 * a curve that is not the one v4 has.
 *
 * This does it with a constraint instead of a curve. The pool is an ordinary v4 pool. The hook computes a floor price
 * that decays from `startPriceX96` to `floorPriceX96` over `duration`, and rejects any swap that buys the launched
 * token below it. Nothing forces the price down; the schedule simply refuses to sell cheaply yet. When a buyer
 * accepts, the pool's own price moves above the floor and the constraint stops binding, which is the auction
 * clearing. When the schedule expires it stops binding forever and the pool is a normal pool.
 *
 * Three properties fall out of doing it this way. Sniping the first block is pointless, because the first block's
 * floor is the start price and there is no discount to capture. Selling is never restricted, at any point in the
 * schedule, so nobody can be trapped in a position by the launch mechanism. And the hook holds nothing, mints
 * nothing and has no privileged role: it can refuse a swap and that is the whole of its power.
 *
 * The decay is linear in time. A geometric schedule is the more common choice in Dutch auctions and would need either
 * an exponential or a lookup table on-chain; linear is exact in integer arithmetic, and a launch that wants a steep
 * early descent can express it by picking a shorter duration and a lower floor.
 *
 * @custom:slug dutch-clearing-launch
 * @custom:family Launch
 * @custom:prior-art Liquidity bootstrapping pools (Balancer LBPs, and the Uni LBP and LBP Hook submissions for v4) run the descent through a weight schedule, which needs a weighted curve. Fair-launch and anti-snipe hooks address the same problem through fees or allowlists. Expressing the auction as a decaying floor price on an otherwise ordinary pool, so the curve is untouched and the constraint simply stops binding once demand arrives, is the contribution here.
 * @custom:limitation It sets a floor on the execution price, so it cannot stop somebody buying at a price far above the floor: it prevents a cheap fill, not an expensive one. A launch with no buyers at any price simply runs the schedule out and becomes an ordinary pool at the floor, which is the correct outcome but not a rescue. And because the floor binds only on buys of the launched token, a pool whose currencies are the other way round must be configured with `buyIsZeroForOne` set accordingly or the constraint will guard the wrong side.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract DutchClearingLaunchHook is ForgeHook, PoolConfigurable {
    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Floor price at the start of the schedule, as a Q96 ratio of currency1 per currency0.
        uint160 startPriceX96;
        /// @notice Floor price once the schedule has run out. Must be at or below `startPriceX96`.
        uint160 floorPriceX96;
        /// @notice When the descent begins, as a unix timestamp.
        uint64 startTime;
        /// @notice How long the descent takes, in seconds. Must be non-zero.
        uint32 duration;
        /// @notice Which swap direction buys the launched token. The floor guards only that direction.
        bool buyIsZeroForOne;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice Whether the auction has cleared: a buy has executed at or above the floor while it was still binding.
    mapping(PoolId => bool) public cleared;

    /// @notice The price the auction cleared at, as a Q96 ratio. Zero until it clears.
    mapping(PoolId => uint256) public clearingPriceX96;

    /// @dev `duration` was zero, which would make the schedule a single instant.
    error InvalidDuration();

    /// @dev The floor must not be above the start price; a schedule that ascends is not a Dutch auction.
    error FloorAboveStart();

    /// @dev The schedule must begin at or after configuration; a descent that already happened is not a schedule.
    error StartInThePast();

    /**
     * @dev The swap would buy below the price the schedule is currently asking.
     * @param floorPriceX96 What the schedule is asking right now.
     * @param executionPriceX96 What this swap would have paid.
     */
    error BelowFloor(uint256 floorPriceX96, uint256 executionPriceX96);

    /// @notice Emitted once per pool, when its schedule is fixed.
    event PoolConfigured(PoolId indexed id, uint160 startPriceX96, uint160 floorPriceX96, uint64 startTime, uint32 duration);

    /// @notice Emitted once, on the swap that clears the auction.
    event AuctionCleared(PoolId indexed id, uint256 clearingPriceX96, uint256 secondsIntoSchedule);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the schedule for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.duration == 0) revert InvalidDuration();
        if (cfg.floorPriceX96 > cfg.startPriceX96) revert FloorAboveStart();
        // A schedule that started before it was configured would already be partly spent, which is never intended.
        // forge-lint: disable-next-line(block-timestamp)
        if (cfg.startTime < block.timestamp) revert StartInThePast();

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.startPriceX96, cfg.floorPriceX96, cfg.startTime, cfg.duration);
    }

    /**
     * @notice The lowest price the schedule will sell at, at `timestamp`, as a Q96 ratio.
     * @dev Linear between the start and the floor. Before the schedule opens it is the start price; after it closes it
     * is the floor, which no longer binds because the constraint is lifted once the schedule expires.
     */
    function floorAt(PoolId id, uint256 timestamp) public view returns (uint256) {
        Config memory cfg = configOf[id];
        if (timestamp <= cfg.startTime) return cfg.startPriceX96;

        uint256 elapsed = timestamp - cfg.startTime;
        if (elapsed >= cfg.duration) return cfg.floorPriceX96;

        uint256 descent = uint256(cfg.startPriceX96) - cfg.floorPriceX96;
        return cfg.startPriceX96 - FeeMath.mulDiv(descent, elapsed, cfg.duration);
    }

    /// @notice The floor right now.
    function currentFloorX96(PoolId id) external view returns (uint256) {
        return floorAt(id, block.timestamp);
    }

    /// @notice Whether the schedule is still constraining swaps.
    function scheduleActive(PoolId id) public view returns (bool) {
        Config memory cfg = configOf[id];
        if (cfg.duration == 0) return false;
        // Schedules run for minutes or hours; proposer drift cannot move a boundary meaningfully.
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < uint256(cfg.startTime) + cfg.duration;
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].duration == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Rejects a buy that filled below the schedule's current floor, and records the clearing price of the first
     * buy that does not.
     *
     * The check runs after the swap because the execution price is the ratio of what actually moved, and that is only
     * knowable from the delta. Reverting here unwinds the swap, so a below-floor fill never lands.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];

        // Selling is never restricted, and once the schedule has run out nothing is.
        if (params.zeroForOne != cfg.buyIsZeroForOne || !scheduleActive(id)) {
            return (this.afterSwap.selector, 0);
        }

        // The buyer pays the currency whose delta is negative and receives the one that is positive. Rather than
        // assume the signs from the direction, read them: a swap that does not have one of each is not a fill this
        // schedule has anything to say about, and inferring a price from it would be inventing one.
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        (int128 paidSigned, int128 receivedSigned) = cfg.buyIsZeroForOne ? (amount0, amount1) : (amount1, amount0);
        if (paidSigned >= 0 || receivedSigned <= 0) return (this.afterSwap.selector, 0);

        // Both casts are safe: the guard above establishes `paidSigned < 0` and `receivedSigned > 0`.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 paid = uint256(uint128(-paidSigned));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 received = uint256(uint128(receivedSigned));

        // Price of the token being bought, expressed the same way as the schedule: paid per received, in Q96.
        uint256 executionPriceX96 = FeeMath.mulDiv(paid, 1 << 96, received);
        uint256 floor = floorAt(id, block.timestamp);
        if (executionPriceX96 < floor) revert BelowFloor(floor, executionPriceX96);

        if (!cleared[id]) {
            cleared[id] = true;
            clearingPriceX96[id] = executionPriceX96;
            emit AuctionCleared(id, executionPriceX96, block.timestamp - cfg.startTime);
        }

        return (this.afterSwap.selector, 0);
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

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "DutchClearingLaunch";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "dutch-clearing-launch.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "launch";
        tags[1] = "auction";
        tags[2] = "price-discovery";
        tags[3] = "anti-snipe";
        tags[4] = "oracle-free";
    }
}
