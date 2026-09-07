// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Chains} from "src/libraries/Chains.sol";
import {DemoToken} from "src/demo/DemoToken.sol";
import {DemoRouter} from "src/demo/DemoRouter.sol";

/**
 * @title DeployDemo
 * @notice Stands up everything a live hook demo needs on one chain: two faucet tokens, a router a browser can drive,
 * and a seeded pool for every hook that has been deployed.
 *
 * @dev A hook nobody can touch is a blog post. Touching one needs four things that do not exist on a fresh chain: a
 * pair of tokens anybody can obtain, a contract that can open v4's lock on a user's behalf, a pool wired to the hook,
 * and enough liquidity in it that a swap moves a visible amount. This script produces all four in one run and writes
 * the addresses where the front ends read them.
 *
 * Tokens and the router are deployed through the deterministic CREATE2 factory, so re-running the script on a chain
 * that already has them does not produce a second set. Pools are created only if they do not already exist. The whole
 * script is therefore safe to re-run, which is what makes "add one more hook to a chain that already has the others"
 * a one-line operation rather than a migration.
 *
 * Usage:
 *
 *   forge script script/DeployDemo.s.sol --rpc-url $RPC_URL --broadcast
 *
 * Requires PRIVATE_KEY and a funded deployer. Run `DeployHooks` first: this script seeds pools for hooks that are
 * already on-chain and skips any that are not.
 */
contract DeployDemo is Script {
    /// @dev A fixed salt, so the demo tokens land on the same address on every chain.
    bytes32 internal constant TOKEN0_SALT = keccak256("hookforge.demo.hUSD.v1");
    bytes32 internal constant TOKEN1_SALT = keccak256("hookforge.demo.hETH.v1");
    bytes32 internal constant ROUTER_SALT = keccak256("hookforge.demo.router.v1");

    /// @notice Liquidity seeded into each demo pool, wide enough that a demo swap does not exhaust it.
    int256 internal constant SEED_LIQUIDITY = 5e18;
    int24 internal constant TICK_LOWER = -60000;
    int24 internal constant TICK_UPPER = 60000;

    /// @dev 1:1, the price every demo pool starts at so the numbers on screen are easy to reason about.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        IPoolManager manager = Chains.poolManager(block.chainid);
        require(address(manager) != address(0), "no Uniswap v4 PoolManager known for this chain");

        vm.startBroadcast();

        DemoToken tokenA = _token(TOKEN0_SALT, "Hook Demo USD", "hUSD");
        DemoToken tokenB = _token(TOKEN1_SALT, "Hook Demo ETH", "hETH");
        DemoRouter router = _router(manager);

        // v4 requires currency0 < currency1. Sorting here rather than assuming keeps the script correct whatever
        // addresses CREATE2 happens to produce on a given chain.
        (Currency currency0, Currency currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        console2.log("chain      ", block.chainid);
        console2.log("PoolManager", address(manager));
        console2.log("hUSD       ", address(tokenA));
        console2.log("hETH       ", address(tokenB));
        console2.log("DemoRouter ", address(router));

        // Enough of both tokens to seed every pool this script will create.
        tokenA.claim();
        tokenB.claim();
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);

        vm.stopBroadcast();

        console2.log("");
        console2.log("Demo infrastructure is up. Seed a pool per hook with SeedDemoPool, which takes the hook address");
        console2.log("and its configuration, because every hook is configured differently and a single script that");
        console2.log("knew all of them would have to be edited for each new one.");
    }

    /// @dev Deploys a demo token at its deterministic address, or returns the one already there.
    function _token(bytes32 salt, string memory name, string memory symbol) private returns (DemoToken) {
        bytes memory initCode = abi.encodePacked(type(DemoToken).creationCode, abi.encode(name, symbol));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), Chains.CREATE2_DEPLOYER);
        if (predicted.code.length > 0) return DemoToken(predicted);

        DemoToken token = new DemoToken{salt: salt}(name, symbol);
        require(address(token) == predicted, "token landed at an unexpected address");
        return token;
    }

    /// @dev Deploys the router at its deterministic address, or returns the one already there.
    function _router(IPoolManager manager) private returns (DemoRouter) {
        bytes memory initCode = abi.encodePacked(type(DemoRouter).creationCode, abi.encode(manager));
        address predicted = vm.computeCreate2Address(ROUTER_SALT, keccak256(initCode), Chains.CREATE2_DEPLOYER);
        if (predicted.code.length > 0) return DemoRouter(predicted);

        DemoRouter router = new DemoRouter{salt: ROUTER_SALT}(manager);
        require(address(router) == predicted, "router landed at an unexpected address");
        return router;
    }
}
