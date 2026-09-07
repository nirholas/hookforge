// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForgeHook} from "../base/ForgeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";

/**
 * @title CircuitBreakerHook
 * @notice Halts swapping for a cooldown after the price moves further than a pool is willing to move in one window,
 * and lets liquidity leave the whole time.
 *
 * @dev Every venue outside crypto stops trading after a limit move, for a reason that has nothing to do with
 * paternalism: a violent move is usually either an error or an attack, and the cheapest defence against both is to
 * stop, let information arrive, and start again. On-chain the same event is normally handled by a governance
 * multisig that pauses a contract minutes after it mattered.
 *
 * This hook makes the rule mechanical and local to one pool. It keeps a reference tick, refreshed at most once per
 * `windowSeconds`. After every swap it compares the new tick to that reference. If the pool moved further than
 * `maxTickMove`, swapping halts for `cooldownSeconds` and then resumes on its own. There is no admin, no pause key
 * and no way for anyone, including the deployer, to halt a pool that has not moved or to extend a halt that has
 * expired.
 *
 * The design decision worth stating: the swap that breaches the limit is allowed to complete. Reverting it instead
 * would turn the hook into a price cap, and a price cap on an AMM is a strictly worse instrument than a halt. It
 * cannot be enforced (the same move arrives as several smaller swaps), it strands the pool at a price the market has
 * left, and it guarantees that the arbitrage against the pool stays open and profitable for as long as the cap holds.
 * Halting after the fact gives up the last swap and buys the thing that actually matters, which is time.
 *
 * Liquidity operations are never blocked. A provider can withdraw during a halt, which is the property that makes
 * this safe to use: the worst case for someone caught in a halted pool is that they exit rather than trade.
 *
 * One tick is one basis point to within rounding (`1.0001^1`), so `maxTickMove = 500` is a five percent move.
 *
 * Prior art: pause-guardian patterns are everywhere and oracle-deviation checks exist as hooks. An autonomous,
 * self-clearing, per-pool halt with no privileged role and no oracle does not.
 */
contract CircuitBreakerHook is ForgeHook, PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Ticks the price may move within a window before trading halts. One tick is one basis point.
        uint24 maxTickMove;
        /// @notice Seconds after which the reference price is refreshed to the current price.
        uint32 windowSeconds;
        /// @notice Seconds trading stays halted once the limit is breached.
        uint32 cooldownSeconds;
    }

    /// @notice The price the current window is measured against.
    struct Reference {
        int24 tick;
        uint64 at;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice The reference price and when it was taken, per pool.
    mapping(PoolId => Reference) public referenceOf;

    /// @notice Timestamp until which swapping is halted, per pool. Zero means never halted.
    mapping(PoolId => uint64) public haltedUntil;

    /// @dev Swapping is halted until `until`. Liquidity may still be added or removed.
    error PoolHalted(uint64 until);

    /// @dev `maxTickMove`, `windowSeconds` and `cooldownSeconds` must all be non-zero.
    error InvalidConfig();

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 maxTickMove, uint32 windowSeconds, uint32 cooldownSeconds);

    /// @notice Emitted when the reference price rolls forward into a new window.
    event ReferenceRolled(PoolId indexed id, int24 tick);

    /// @notice Emitted when a limit move halts the pool.
    event Tripped(PoolId indexed id, int24 referenceTick, int24 tick, uint64 until);

    constructor(IPoolManager _poolManager) ForgeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.maxTickMove == 0 || cfg.windowSeconds == 0 || cfg.cooldownSeconds == 0) revert InvalidConfig();

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.maxTickMove, cfg.windowSeconds, cfg.cooldownSeconds);
    }

    /// @notice Whether swapping is currently halted for `id`.
    function isHalted(PoolId id) public view returns (bool) {
        return block.timestamp < haltedUntil[id];
    }

    /// @notice How far the pool has moved from its reference, in ticks.
    function moveFromReference(PoolId id) public view returns (uint256) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        int24 refTick = referenceOf[id].tick;
        return uint256(int256(tick > refTick ? tick - refTick : refTick - tick));
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
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Requires a configuration, and takes the first reference price.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        if (configOf[id].maxTickMove == 0) revert PoolNotConfigured();

        referenceOf[id] = Reference(tick, uint64(block.timestamp));
        emit ReferenceRolled(id, tick);
        return this.afterInitialize.selector;
    }

    /// @dev Rejects swaps during a halt, and rolls the reference forward when the window has elapsed.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));

        uint64 until = haltedUntil[id];
        if (block.timestamp < until) revert PoolHalted(until);

        Reference memory window = referenceOf[id];
        if (block.timestamp - window.at >= configOf[id].windowSeconds) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            referenceOf[id] = Reference(tick, uint64(block.timestamp));
            emit ReferenceRolled(id, tick);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Halts the pool if the completed swap took it past the limit for this window.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));

        (, int24 tick,,) = poolManager.getSlot0(id);
        int24 refTick = referenceOf[id].tick;
        uint256 move = uint256(int256(tick > refTick ? tick - refTick : refTick - tick));

        if (move > configOf[id].maxTickMove) {
            uint64 until = uint64(block.timestamp) + configOf[id].cooldownSeconds;
            haltedUntil[id] = until;
            emit Tripped(id, refTick, tick, until);
        }

        return (this.afterSwap.selector, 0);
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "CircuitBreaker";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "circuit-breaker.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "risk";
        tags[1] = "circuit-breaker";
        tags[2] = "oracle-free";
        tags[3] = "no-admin";
    }
}
