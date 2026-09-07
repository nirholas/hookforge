// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {Chains} from "src/libraries/Chains.sol";
import {IHookMetadata} from "src/interfaces/IHookMetadata.sol";
import {ArbTaxDecayHook} from "src/hooks/ArbTaxDecayHook.sol";
import {PriorityFeeTaxHook} from "src/hooks/PriorityFeeTaxHook.sol";
import {CircuitBreakerHook} from "src/hooks/CircuitBreakerHook.sol";
import {DepegShieldHook} from "src/hooks/DepegShieldHook.sol";
import {AntiSnipeRampHook} from "src/hooks/AntiSnipeRampHook.sol";
import {OracleBandHook} from "src/hooks/OracleBandHook.sol";
import {LiquidityFloorHook} from "src/hooks/LiquidityFloorHook.sol";
import {TradingCalendarHook} from "src/hooks/TradingCalendarHook.sol";
import {RatchetFloorHook} from "src/hooks/RatchetFloorHook.sol";
import {DrawdownCapHook} from "src/hooks/DrawdownCapHook.sol";

/**
 * @title DeployHooks
 * @notice Deploys the HookForge catalogue deterministically to any chain with a Uniswap v4 `PoolManager`.
 *
 * @dev A v4 hook only works at an address whose low fourteen bits spell out the callbacks it implements, so every
 * deployment starts by mining a CREATE2 salt. Mining against `Chains.CREATE2_DEPLOYER` makes the result reproducible:
 * anyone can re-run this script against a chain and derive the same address without trusting the published one.
 *
 * The address is *not* the same on every chain. A hook takes its `PoolManager` as a constructor argument, so the init
 * code differs per chain and so does the CREATE2 result. What is guaranteed is that the address is a pure function of
 * (hook source, compiler settings, chain), which is the property that matters for verification.
 *
 * Usage:
 *
 *   forge script script/DeployHooks.s.sol --rpc-url base --broadcast --verify
 *   forge script script/DeployHooks.s.sol --rpc-url robinhood --broadcast --gas-limit 30000000000
 *
 * Salt mining is a loop, and how long it runs depends on the chain (the `PoolManager` address is part of the init
 * code, so each chain searches a different space). Some chains need more headroom than the default script gas limit
 * allows and fail with `EvmError: OutOfGas` in the miner rather than anywhere interesting; `--gas-limit` fixes it and
 * costs nothing, since mining is a view loop that never reaches the chain.
 *
 * Requires `PRIVATE_KEY` in the environment (or `--account` / `--ledger`). The addresses are written to
 * `deployments/<chainId>.json`, which `packages/registry` reads when it builds the published address book.
 *
 * Re-running is safe. A hook already deployed at its mined address is skipped rather than redeployed, so this script
 * doubles as the way to add one new hook to a chain that already has the others.
 */
contract DeployHooks is Script {
    IPoolManager internal manager;
    string internal json;

    uint160 internal constant FEE_HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    uint160 internal constant BREAKER_FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint160 internal constant RATCHET_FLOOR_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint160 internal constant LIQUIDITY_FLOOR_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function run() external {
        manager = Chains.poolManager();
        console2.log("chain", block.chainid);
        console2.log("poolManager", address(manager));

        vm.startBroadcast();

        _record("ArbTaxDecay", _deployArbTaxDecay());
        _record("PriorityFeeTax", _deployPriorityFeeTax());
        _record("CircuitBreaker", _deployCircuitBreaker());
        _record("DepegShield", _deployDepegShield());
        _record("AntiSnipeRamp", _deployAntiSnipeRamp());
        _record("OracleBand", _deployOracleBand());
        _record("LiquidityFloor", _deployLiquidityFloor());
        _record("TradingCalendar", _deployTradingCalendar());
        _record("RatchetFloor", _deployRatchetFloor());
        _record("DrawdownCap", _deployDrawdownCap());

        vm.stopBroadcast();

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }

    function _deployArbTaxDecay() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, FEE_HOOK_FLAGS, type(ArbTaxDecayHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        ArbTaxDecayHook hook = new ArbTaxDecayHook{salt: salt}(manager);
        require(address(hook) == expected, "ArbTaxDecay: mined address mismatch");
        return address(hook);
    }

    function _deployPriorityFeeTax() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, FEE_HOOK_FLAGS, type(PriorityFeeTaxHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        PriorityFeeTaxHook hook = new PriorityFeeTaxHook{salt: salt}(manager);
        require(address(hook) == expected, "PriorityFeeTax: mined address mismatch");
        return address(hook);
    }

    function _deployCircuitBreaker() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, BREAKER_FLAGS, type(CircuitBreakerHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        CircuitBreakerHook hook = new CircuitBreakerHook{salt: salt}(manager);
        require(address(hook) == expected, "CircuitBreaker: mined address mismatch");
        return address(hook);
    }

    function _deployDepegShield() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, FEE_HOOK_FLAGS, type(DepegShieldHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        DepegShieldHook hook = new DepegShieldHook{salt: salt}(manager);
        require(address(hook) == expected, "DepegShield: mined address mismatch");
        return address(hook);
    }

    function _deployAntiSnipeRamp() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, FEE_HOOK_FLAGS, type(AntiSnipeRampHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        AntiSnipeRampHook hook = new AntiSnipeRampHook{salt: salt}(manager);
        require(address(hook) == expected, "AntiSnipeRamp: mined address mismatch");
        return address(hook);
    }

    function _deployOracleBand() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, BREAKER_FLAGS, type(OracleBandHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        OracleBandHook hook = new OracleBandHook{salt: salt}(manager);
        require(address(hook) == expected, "OracleBand: mined address mismatch");
        return address(hook);
    }

    function _deployLiquidityFloor() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, LIQUIDITY_FLOOR_FLAGS, type(LiquidityFloorHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        LiquidityFloorHook hook = new LiquidityFloorHook{salt: salt}(manager);
        require(address(hook) == expected, "LiquidityFloor: mined address mismatch");
        return address(hook);
    }

    function _deployTradingCalendar() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, FEE_HOOK_FLAGS, type(TradingCalendarHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        TradingCalendarHook hook = new TradingCalendarHook{salt: salt}(manager);
        require(address(hook) == expected, "TradingCalendar: mined address mismatch");
        return address(hook);
    }

    function _deployRatchetFloor() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, RATCHET_FLOOR_FLAGS, type(RatchetFloorHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        RatchetFloorHook hook = new RatchetFloorHook{salt: salt}(manager);
        require(address(hook) == expected, "RatchetFloor: mined address mismatch");
        return address(hook);
    }

    function _deployDrawdownCap() internal returns (address) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, BREAKER_FLAGS, type(DrawdownCapHook).creationCode, args);
        if (expected.code.length > 0) return expected;

        DrawdownCapHook hook = new DrawdownCapHook{salt: salt}(manager);
        require(address(hook) == expected, "DrawdownCap: mined address mismatch");
        return address(hook);
    }

    /// @dev Logs the deployment and folds it into the JSON written at the end of the run.
    function _record(string memory name, address hook) internal {
        console2.log(name, hook);
        require(
            keccak256(bytes(IHookMetadata(hook).hookName())) == keccak256(bytes(name)),
            "deployed hook does not answer to its own name"
        );
        json = vm.serializeAddress("hooks", name, hook);
    }
}
