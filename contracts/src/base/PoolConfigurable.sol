// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/**
 * @title PoolConfigurable
 * @notice Permissionless per-pool configuration for hooks, locked at pool initialization.
 * @dev Uniswap v4 removed `hookData` from `initialize`, so a hook that needs per-pool parameters has to receive them
 * out of band. The pattern here is: anyone may call the hook's `configure` function for a pool key whose pool does not
 * exist yet, and no one may change it afterwards. Since the parameters are part of what the pool *is*, and a pool key
 * is only worth initializing by the party that wants that pool, the party that configures is in practice the party
 * that creates the pool.
 *
 * A griefer can configure a key they do not intend to initialize. The remedy is cheap and local: the creator picks a
 * different `tickSpacing` (or fee, or hook salt), which is a different pool id, and configures that one. Nothing is
 * lost but the griefer's gas. This is why configuration is never re-openable: a mutable config would let the same
 * griefer change the terms of a live pool under its liquidity providers.
 *
 * Initialization state is read from the `PoolManager` rather than mirrored locally, so the two can never disagree.
 */
abstract contract PoolConfigurable {
    using StateLibrary for IPoolManager;

    /// @dev The pool already exists, so its configuration is final.
    error PoolAlreadyInitialized();

    /// @dev The pool was initialized without a configuration for this hook.
    error PoolNotConfigured();

    /// @notice The `PoolManager` this hook is bound to. Provided by the inheriting hook.
    function _manager() internal view virtual returns (IPoolManager);

    /// @dev Reverts unless the pool for `key` has not been initialized yet.
    function _requireUninitialized(PoolKey calldata key) internal view {
        (uint160 sqrtPriceX96,,,) = _manager().getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        if (sqrtPriceX96 != 0) revert PoolAlreadyInitialized();
    }

    /// @notice Whether the pool for `id` exists in the `PoolManager`.
    function isPoolInitialized(PoolId id) public view returns (bool) {
        (uint160 sqrtPriceX96,,,) = _manager().getSlot0(id);
        return sqrtPriceX96 != 0;
    }
}
