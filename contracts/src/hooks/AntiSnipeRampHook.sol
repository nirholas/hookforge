// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title AntiSnipeRampHook
 * @notice Opens a pool at a punitive fee that decays to normal over a fixed window, and pays every cent of the
 * difference to liquidity providers rather than to the deployer.
 *
 * @dev The first block of a new pool is the most valuable block it will ever have. A bot that buys in it and sells an
 * hour later takes the entire launch premium, and everyone who arrives through the front door pays for it. The usual
 * answers are a whitelist, which is a promise rather than a mechanism, or a bonding curve that hands the premium to
 * the deployer, which moves the extraction rather than removing it.
 *
 * This hook makes the first block expensive to trade in and lets that expense decay:
 *
 *   fee(t) = startFee - (startFee - endFee) * min(t, rampSeconds) / rampSeconds
 *
 * A sniper in the first second pays `startFee`, which can be set high enough that the trade is not worth making. A
 * buyer twenty minutes later pays close to `endFee`. Because the fee is an LP fee, the premium the early trader
 * surrenders is paid to the people who put the liquidity up, not to whoever deployed the token. There is no address in
 * this contract that can receive anything.
 *
 * A second lever handles the case where the fee alone is not enough. While the ramp is running, a single swap may not
 * exceed `maxSwapDuringRamp` units of the specified currency. This is a size cap, not an identity check, and it is
 * deliberately not per-address: a hook sees the router that called the `PoolManager`, not the person behind it, so any
 * per-address limit is a limit on routers and is defeated by a fresh key. Capping size is enforceable against everyone
 * equally, including the deployer. Set it to zero to disable it.
 *
 * Prior art: liquidity bootstrapping pools ramp the *price* down and were built for price discovery; several launchpad
 * hooks charge a launch fee and route it to a creator or a protocol treasury. Ramping the *fee* down while directing
 * the proceeds to liquidity is a different mechanism with a different beneficiary, and it composes with any curve
 * rather than replacing it.
 *
 * @custom:slug anti-snipe-ramp
 * @custom:family Launch
 * @custom:prior-art Liquidity bootstrapping pools ramp the price down and were built for price discovery; several launchpad hooks charge a launch fee and route it to a creator or a treasury. Ramping the fee down while directing the proceeds to liquidity is a different mechanism with a different beneficiary, and it composes with any curve rather than replacing it.
 * @custom:limitation The size cap is per swap, not per address: a hook sees the router that called the PoolManager, not the person behind it, so a determined buyer can split across transactions. The cap raises the cost of sniping rather than preventing it, and the fee ramp is what does the real work.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon,bnb
 */
contract AntiSnipeRampHook is ForgeFeeHook, PoolConfigurable {
    /// @notice Per-pool parameters, fixed at initialization.
    struct Config {
        /// @notice Fee at the moment the pool opens, in hundredths of a bip. `500_000` is 50%.
        uint24 startFee;
        /// @notice Fee once the ramp has fully elapsed.
        uint24 endFee;
        /// @notice Length of the ramp in seconds. Must be non-zero.
        uint32 rampSeconds;
        /// @notice Largest single swap allowed while the ramp runs, in units of the specified currency. Zero disables.
        uint128 maxSwapDuringRamp;
    }

    /// @notice Parameters for each configured pool.
    mapping(PoolId => Config) public configOf;

    /// @notice When each pool opened.
    mapping(PoolId => uint64) public openedAt;

    /// @dev `rampSeconds` was zero, or `endFee` was above `startFee`, which would ramp the fee upward.
    error InvalidConfig();

    /// @dev The swap is larger than the pool allows while its launch ramp is running.
    error SwapTooLargeDuringRamp(uint256 requested, uint128 allowed);

    /// @notice Emitted once per pool, when its parameters are fixed.
    event PoolConfigured(PoolId indexed id, uint24 startFee, uint24 endFee, uint32 rampSeconds, uint128 maxSwap);

    /// @notice Emitted on every swap during and after the ramp.
    event RampPriced(PoolId indexed id, uint256 elapsedSeconds, uint24 fee);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /// @notice Fix the parameters for a pool that does not exist yet. See {PoolConfigurable}.
    function configure(PoolKey calldata key, Config calldata cfg) external {
        _requireUninitialized(key);
        if (cfg.rampSeconds == 0 || cfg.endFee > cfg.startFee) revert InvalidConfig();
        FeeMath.requireValid(cfg.startFee);

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        configOf[id] = cfg;
        emit PoolConfigured(id, cfg.startFee, cfg.endFee, cfg.rampSeconds, cfg.maxSwapDuringRamp);
    }

    /// @notice The fee this pool charges right now.
    function quoteFee(PoolId id) public view returns (uint24) {
        return _feeAt(configOf[id], block.timestamp - openedAt[id]);
    }

    /// @notice Whether the launch ramp is still running for `id`.
    function isRamping(PoolId id) public view returns (bool) {
        // Safe against timestamp drift: the launch ramp is measured in minutes, so the seconds a proposer can shift `block.timestamp` by
        // cannot buy a materially cheaper fee, and shifting it forward only ends the ramp sooner for everyone.
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp - openedAt[id] < configOf[id].rampSeconds;
    }

    /// @dev Requires a configuration, and starts the ramp.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        if (configOf[id].rampSeconds == 0) revert PoolNotConfigured();

        openedAt[id] = uint64(block.timestamp);
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Config memory cfg = configOf[id];
        uint256 elapsed = block.timestamp - openedAt[id];

        if (elapsed < cfg.rampSeconds && cfg.maxSwapDuringRamp != 0) {
            int256 specified = params.amountSpecified;
            uint256 size = uint256(specified >= 0 ? specified : -specified);
            if (size > cfg.maxSwapDuringRamp) revert SwapTooLargeDuringRamp(size, cfg.maxSwapDuringRamp);
        }

        uint24 fee = _feeAt(cfg, elapsed);
        emit RampPriced(id, elapsed, fee);
        return fee;
    }

    /// @dev Linear decay from `startFee` to `endFee`, flat at `endFee` once the ramp has elapsed.
    function _feeAt(Config memory cfg, uint256 elapsed) private pure returns (uint24) {
        if (elapsed >= cfg.rampSeconds) return cfg.endFee;
        uint256 shed = FeeMath.mulDiv(uint256(cfg.startFee) - cfg.endFee, elapsed, cfg.rampSeconds);
        // Safe against timestamp drift: the launch ramp is measured in minutes, so the seconds a proposer can shift `block.timestamp` by
        // cannot buy a materially cheaper fee, and shifting it forward only ends the ramp sooner for everyone.
        // forge-lint: disable-next-line(block-timestamp)
        // casting to 'uint24' is safe because `shed` is `(startFee - endFee) * elapsed / rampSeconds` with
        // `elapsed < rampSeconds`, so it is strictly less than `startFee` and the difference stays a uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(cfg.startFee) - shed);
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "AntiSnipeRamp";
    }

    function specURI() external pure override returns (string memory) {
        return string.concat(SPEC_BASE, "anti-snipe-ramp.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "launch";
        tags[1] = "anti-snipe";
        tags[2] = "dynamic-fee";
        tags[3] = "no-admin";
    }
}
