// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";

import {ForgeMetadata} from "./ForgeMetadata.sol";

/**
 * @title ForgeHook
 * @notice Base for HookForge hooks that do not override the pool fee: OpenZeppelin's audited {BaseHook} plus
 * HookForge's on-chain {IHookMetadata}.
 */
abstract contract ForgeHook is BaseHook, ForgeMetadata {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}
}
