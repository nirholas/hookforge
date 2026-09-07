// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title LiquidityFloorHook
 * @notice A liquidity commitment enforced per position: a fraction of what you add cannot leave until the pool's
 * unlock date, and every provider is held to that fraction of their own stake rather than to a shared pool total.
 *
 * @dev A new pool has a bootstrapping problem that is really a credibility problem. Swappers cannot tell the
 * difference between liquidity that intends to stay and liquidity that will leave the moment the pool is quoted by an
 * aggregator, and the second kind is indistinguishable from the first right up until it is gone.
 *
 * The published answers lock whole positions for a term. That works and it is also badly mispriced: a provider who
 * would happily commit a third of their capital for six months has to choose between committing all of it and
 * committing none. Term locks therefore select for the providers least sensitive to the lock, which is not the same
 * set as the providers most useful to the pool.
 *
 * This hook takes the commitment as a *fraction*. Configure `floorBps` and `unlockTimestamp`, and thereafter each
 * position may freely withdraw down to `floorBps` of everything it has ever added, with the remainder released at the
 * unlock. Adding more liquidity raises your own floor proportionally, so topping up is never a trap: you keep the same
 * ratio of free to committed capital that you signed up for.
 *
 * The design is deliberately race-free, which is the property that distinguishes it from a pool-wide minimum. A floor
 * expressed as "total pool liquidity must stay above X" is a bank run waiting to happen: it is satisfiable by whoever
 * withdraws first and binding only on whoever is last, so rational providers race for the exit precisely when the pool
 * most needs them. Holding each position to its own commitment removes the race entirely. Nothing another provider
 * does can change what you are allowed to withdraw.
 *
 * The hook takes no fee, holds no funds and has no privileged role. It cannot stop a provider from ceasing to quote,
 * only from removing committed liquidity, and it does not restrict swaps at all.
 *
 * Position identity is the v4 position key: the address that called `modifyLiquidity` on the `PoolManager` (in
 * practice a position manager or a router), the tick range, and the caller's salt. Two providers sharing one position
 * manager therefore share a commitment only if they also share a salt, which position managers do not do.
 *
 * Prior art: `LiquidityLock`, `Timelock Addition` and `LockingLiquidity` all lock positions wholesale for a term.
 * Fractional, per-position, top-up-safe commitments are the contribution here.
 *
 * @custom:slug liquidity-floor
 * @custom:family Liquidity provider economics
 * @custom:prior-art LiquidityLock, Timelock Addition and LockingLiquidity all lock positions wholesale for a term. Fractional, per-position, top-up-safe commitments are the contribution here, along with the observation that a pool-wide minimum is a bank run rather than a floor.
 * @custom:limitation The commitment binds the v4 position key, which is the address that called modifyLiquidity. A provider who routes through a position manager that pools many users under one key would share a commitment with them; every mainstream position manager gives each position its own key, but a custom router need not.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract LiquidityFloorHook is ForgeHook, PoolConfigurable {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Fraction of each position's cumulative additions that is committed, in basis points. Non-zero.
        uint16 floorBps;
        /// @notice Timestamp at which the commitment lapses and all liquidity becomes free.
        uint64 unlockTimestamp;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice Liquidity each position has ever added, per pool. Never decreases.
    mapping(PoolId => mapping(bytes32 => uint256)) public addedLiquidity;

    /// @notice Liquidity each position has removed, per pool.
    mapping(PoolId => mapping(bytes32 => uint256)) public removedLiquidity;

    /// @dev `floorBps` was zero (no commitment) or above 100%.
    error InvalidFloor();

    /// @dev The unlock must be in the future at configuration time, or the commitment means nothing.
    error UnlockInThePast();

    /**
     * @dev The withdrawal would take the position below its commitment.
     * @param committed Liquidity this position must leave in place until the unlock.
     * @param remaining Liquidity the position would have left if this withdrawal succeeded.
     */
    error CommitmentBreached(uint256 committed, uint256 remaining);

    /// @notice Emitted once per pool, when its commitment terms are fixed.
    event PoolConfigured(PoolId indexed id, uint16 floorBps, uint64 unlockTimestamp);

    /// @notice Emitted whenever a position's commitment changes because it added liquidity.
    event CommitmentIncreased(PoolId indexed id, bytes32 indexed position, uint256 added, uint256 committed);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the commitment terms for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        if (cfg.floorBps == 0 || cfg.floorBps > BPS) revert InvalidFloor();
        // Commitments are measured in days or months, so the seconds of drift a proposer can introduce cannot
        // meaningfully move an unlock.
        // forge-lint: disable-next-line(block-timestamp)
        if (cfg.unlockTimestamp <= block.timestamp) revert UnlockInThePast();

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.floorBps, cfg.unlockTimestamp);
    }

    /// @notice The v4 position key for a range owned by `owner` with `salt`.
    function positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    /// @notice Liquidity `position` must leave in place right now. Zero once the unlock has passed.
    function committedLiquidity(PoolId id, bytes32 position) public view returns (uint256) {
        Config memory cfg = configOf[id];
        // Same reasoning as in `configure`: an unlock measured in days is not manipulable by seconds of drift.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= cfg.unlockTimestamp) return 0;
        return (addedLiquidity[id][position] * cfg.floorBps) / BPS;
    }

    /// @notice Liquidity `position` may still withdraw right now.
    function withdrawableLiquidity(PoolId id, bytes32 position) public view returns (uint256) {
        uint256 added = addedLiquidity[id][position];
        uint256 removed = removedLiquidity[id][position];
        uint256 held = added > removed ? added - removed : 0;
        uint256 committed = committedLiquidity(id, position);
        return held > committed ? held - committed : 0;
    }

    /// @dev Requires a configuration before the pool may exist.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        if (configOf[PoolId.wrap(keccak256(abi.encode(key)))].floorBps == 0) revert PoolNotConfigured();
        return this.afterInitialize.selector;
    }

    /// @dev Records the addition, which raises this position's own commitment proportionally.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta > 0) {
            PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
            bytes32 position = positionKey(sender, params.tickLower, params.tickUpper, params.salt);
            uint256 added = addedLiquidity[id][position] + uint256(params.liquidityDelta);
            addedLiquidity[id][position] = added;
            emit CommitmentIncreased(id, position, uint256(params.liquidityDelta), committedLiquidity(id, position));
        }
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @dev Rejects a withdrawal that would take the position below its own commitment.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        if (params.liquidityDelta < 0) {
            PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
            bytes32 position = positionKey(sender, params.tickLower, params.tickUpper, params.salt);

            uint256 removing = uint256(-params.liquidityDelta);
            uint256 added = addedLiquidity[id][position];
            uint256 removed = removedLiquidity[id][position] + removing;

            uint256 remaining = added > removed ? added - removed : 0;
            uint256 committed = committedLiquidity(id, position);
            if (remaining < committed) revert CommitmentBreached(committed, remaining);

            removedLiquidity[id][position] = removed;
        }
        return this.beforeRemoveLiquidity.selector;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
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

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "LiquidityFloor";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "liquidity-floor.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "lp-economics";
        tags[1] = "commitment";
        tags[2] = "launch";
        tags[3] = "rug-resistance";
    }
}
