// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title RangeRentHook
 * @notice Makes a tick range something one provider holds, by renting it to them exclusively.
 *
 * @dev Concentrated liquidity is a commons. Anybody may add to any range at any time, and the moment a range becomes
 * profitable everybody piles into it, which is how just-in-time liquidity works: watch for a large swap, add
 * liquidity for one block at exactly the right ticks, take a share of the fee, and withdraw. The capital was never at
 * risk and it collected as though it had been. The providers who sat in that range through the quiet week are diluted
 * by somebody who arrived for one transaction.
 *
 * Every defence so far has taxed the symptom: a fee that punishes short-lived positions, a lock-up, a
 * tenure weight. They all penalise legitimate providers who happen to leave, and none of them stop the strategy,
 * because the payoff scales with the swap and the penalty does not.
 *
 * This removes the commons instead. A range can be leased, and while it is leased nobody but the lessee may add
 * liquidity to it. The lease is bought for a period at a rent the market sets by competition, since anybody may take
 * an unleased range and anybody may outbid an expiring one. Just-in-time liquidity is not made expensive; it is made
 * impossible, because the attacker cannot add at the ticks that matter.
 *
 * The rent goes to the pool, donated to whoever is providing when it settles. So a provider who wants to be alone in
 * a range pays for the privilege, and the payment goes to the providers who are sharing the rest of the pool with
 * them.
 *
 * Unleased ranges stay a commons, which is the point: a pool wearing this hook is not closed, it is one where the
 * ranges worth defending can be defended.
 *
 * @custom:slug range-rent
 * @custom:family Liquidity management
 * @custom:prior-art Just-in-time liquidity is well documented and the mitigations are all penalties: time-weighted fee shares, withdrawal delays, and this catalogue's own TenureWeightedFees. Auction-managed AMMs sell the right to set a pool's fee, and this catalogue's TickHarberger sells that right per range. Renting exclusive *provision* rights to a tick range, so that nobody else may add liquidity there at all, is the contribution here, and it is a different right from the one TickHarberger sells.
 * @custom:limitation Exclusivity is enforced against the address that calls the pool, which for a router-carried position is the router rather than the person behind it, so a lessee has to provide through an address they control and a lease taken out on a shared router is shared with everybody using it. Beyond that, exclusivity is genuine and so is its cost: a leased range holds only one provider's capital, so a pool whose best ranges are all leased is thinner than one where anybody could join. Leases are fixed-term rather than continuously contestable, so an incumbent holds their range until it expires however valuable it becomes; the term is the pool's choice and a long one is a long monopoly. Rent reaches providers through `donate`, which credits whoever is in range at settlement rather than through the lease, and `settleRent` is callable by anyone precisely so that gap stays small. And a lessee who leaves their range empty has bought silence rather than liquidity, which is a legitimate thing to buy and worth knowing is possible.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract RangeRentHook is ForgeHook, PoolConfigurable, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    /// @notice Per-pool terms, fixed before the pool exists.
    struct Config {
        /// @notice Width of one leasable range, in ticks. A multiple of the pool's tick spacing.
        int24 rangeWidth;
        /// @notice Rent per second for one range, in currency1.
        uint128 rentPerSecond;
        /// @notice The shortest a lease may run for.
        uint32 minTerm;
        /// @notice The longest a lease may run for, which is also the longest anybody can be shut out.
        uint32 maxTerm;
    }

    /// @notice A standing lease on one range.
    struct Lease {
        /// @notice Who holds it. Only they may add liquidity overlapping this range.
        address holder;
        /// @notice When it expires and the range returns to the commons.
        uint64 expiresAt;
    }

    /// @notice Terms for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The standing lease on each range of each pool.
    mapping(PoolId => mapping(int256 => Lease)) public leaseOf;

    /// @notice Rent collected and not yet donated to the pool's providers, in currency1.
    mapping(PoolId => uint256) public pendingRent;

    /// @dev A range narrower than the tick spacing, or not a whole number of them, cannot be a range.
    error InvalidRangeWidth();

    /// @dev A rent of zero would make exclusivity free, and terms must be a real interval.
    error InvalidTerms();

    /// @dev The requested term is outside what this pool leases.
    error TermOutOfRange(uint32 shortest, uint32 longest);

    /// @dev Somebody else holds this range until `until`.
    error RangeLeased(address holder, uint64 until);

    /// @dev The position overlaps a range leased to somebody else.
    error RangeNotYours(int256 range, address holder);

    /// @dev A position spanning more ranges than this cannot be checked within a sensible gas budget.
    error PositionTooWide();

    /// @dev There is nothing to settle.
    error NothingToSettle();

    /// @dev Only the `PoolManager` may drive the unlock callback.
    error CallbackNotPoolManager();

    /**
     * @notice The most ranges one position may span.
     * @dev A bound rather than a preference. Checking a position against every range it covers is a loop, and an
     * unbounded loop inside `beforeAddLiquidity` is a denial of service against the pool rather than a slow call.
     */
    uint256 public constant MAX_RANGES_PER_POSITION = 32;

    /// @notice Emitted when a range is leased.
    event Leased(PoolId indexed id, int256 indexed range, address indexed holder, uint64 until, uint256 rent);

    /// @notice Emitted when collected rent is donated to the pool's providers.
    event RentSettled(PoolId indexed id, uint256 amount);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix a pool's terms before it exists. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.rangeWidth <= 0 || cfg.rangeWidth % key.tickSpacing != 0) revert InvalidRangeWidth();
        if (cfg.rentPerSecond == 0 || cfg.minTerm == 0 || cfg.maxTerm < cfg.minTerm) revert InvalidTerms();

        _requireUninitialized(key);
        configOf[PoolId.wrap(keccak256(abi.encode(key)))] = cfg;
    }

    /// @notice The range index a tick falls in. Floor division, so the ranges tile the tick space evenly.
    function rangeOf(int24 tick, int24 width) public pure returns (int256) {
        int256 t = tick;
        int256 w = width;
        return t >= 0 ? t / w : -((-t + w - 1) / w);
    }

    /// @notice What a lease of `term` seconds costs.
    function rentFor(PoolKey calldata key, uint32 term) public view returns (uint256) {
        return uint256(configOf[key.toId()].rentPerSecond) * term;
    }

    /// @notice Whether a range is currently held by somebody, and by whom.
    function heldBy(PoolKey calldata key, int256 range) public view returns (address holder, uint64 until) {
        Lease memory standing = leaseOf[key.toId()][range];
        // A lease that has run out is not a lease, so an expired one reads as vacant rather than as held.
        // forge-lint: disable-next-line(block-timestamp)
        if (standing.holder == address(0) || standing.expiresAt <= block.timestamp) return (address(0), 0);
        return (standing.holder, standing.expiresAt);
    }

    /**
     * @notice Lease a range exclusively for `term` seconds.
     * @dev Available only when the range is vacant or its lease has run out. An incumbent cannot be outbid mid-term,
     * which is the difference between a lease and a Harberger tax: this one is a promise for a fixed period.
     */
    function lease(PoolKey calldata key, int256 range, uint32 term) external {
        PoolId id = key.toId();
        Config memory cfg = configOf[id];
        if (cfg.rangeWidth == 0) revert PoolNotConfigured();
        if (term < cfg.minTerm || term > cfg.maxTerm) revert TermOutOfRange(cfg.minTerm, cfg.maxTerm);

        (address holder, uint64 until) = heldBy(key, range);
        if (holder != address(0) && holder != msg.sender) revert RangeLeased(holder, until);

        uint256 rent = uint256(cfg.rentPerSecond) * term;
        IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), rent);
        pendingRent[id] += rent;

        // Extending your own lease adds to whatever is left rather than restarting it, so renewing early is neither
        // rewarded nor punished.
        // Terms are measured in hours or days, so the seconds a proposer controls cannot meaningfully move an
        // expiry, and the only effect either way is on the renewer's own lease.
        // forge-lint: disable-next-line(block-timestamp)
        uint64 from = holder == msg.sender && until > uint64(block.timestamp) ? until : uint64(block.timestamp);
        leaseOf[id][range] = Lease({holder: msg.sender, expiresAt: from + term});

        emit Leased(id, range, msg.sender, from + term, rent);
    }

    /**
     * @notice Donate the pool's collected rent to its liquidity providers. Callable by anyone.
     * @dev Nobody is paid for calling it: the people who want it called are the providers it pays, and a bounty would
     * only come out of the same money.
     */
    function settleRent(PoolKey calldata key) external {
        PoolId id = key.toId();
        uint256 amount = pendingRent[id];
        if (amount == 0) revert NothingToSettle();
        pendingRent[id] = 0;

        poolManager.unlock(abi.encode(key, amount));
        emit RentSettled(id, amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackNotPoolManager();
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));

        poolManager.donate(key, 0, amount, "");
        poolManager.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
        return "";
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].rangeWidth == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Refuses a position that overlaps a range somebody else holds.
     *
     * Checked across every range the position spans rather than just its ends, because a position wide enough to
     * straddle a leased range would otherwise add liquidity right through it.
     *
     * The caller here is whoever called the pool, which for a router-carried add is the router, not the person who
     * asked for it. That is a real constraint and not one a hook can design around: `beforeAddLiquidity` is told the
     * caller and nothing else, and accepting a claimed identity from `hookData` would let anybody assert they were
     * the lessee. So a lessee has to add through an address they control, and a lease taken out on a shared router
     * is exclusive to everybody using that router. Pools meant for this hook should expect positions to arrive from
     * per-user contracts or from a router that is itself the lessee.
     */
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];

        int256 first = rangeOf(params.tickLower, cfg.rangeWidth);
        int256 last = rangeOf(params.tickUpper, cfg.rangeWidth);
        if ((last - first).toUint256() >= MAX_RANGES_PER_POSITION) revert PositionTooWide();

        for (int256 range = first; range <= last; range++) {
            Lease memory held = leaseOf[id][range];
            // forge-lint: disable-next-line(block-timestamp)
            if (held.holder == address(0) || held.expiresAt <= block.timestamp) continue;
            if (held.holder != sender) revert RangeNotYours(range, held.holder);
        }
        return this.beforeAddLiquidity.selector;
    }

    /// @inheritdoc PoolConfigurable
    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
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
        return "RangeRent";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "range-rent.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](5);
        tags[0] = "liquidity";
        tags[1] = "jit-defence";
        tags[2] = "exclusivity";
        tags[3] = "concentrated";
        tags[4] = "no-admin";
    }
}
