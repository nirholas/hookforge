// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";

import {ForgeMetadata} from "./ForgeMetadata.sol";

/**
 * @title ForgeFeeHook
 * @notice Base for HookForge hooks that price every swap by overriding the pool's LP fee.
 * @dev Combines OpenZeppelin's {BaseOverrideFee}, which enforces that the pool was initialized with the dynamic-fee
 * flag and applies `OVERRIDE_FEE_FLAG` to the fee returned from `_getFee`, with HookForge's on-chain
 * {IHookMetadata}. The fee an override hook charges is an *LP* fee: it is paid to in-range liquidity, not to the
 * hook, so hooks built on this base never custody swapper funds.
 */
abstract contract ForgeFeeHook is BaseOverrideFee, ForgeMetadata {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}
}
