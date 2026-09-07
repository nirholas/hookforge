// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DemoUSDC} from "src/demo/DemoUSDC.sol";
import {DemoToken} from "src/demo/DemoToken.sol";
import {DemoRouter} from "src/demo/DemoRouter.sol";
import {X402GateHook} from "src/hooks/X402GateHook.sol";

/**
 * @title DeployLocal
 * @notice Stands the whole demo up on a local chain: a `PoolManager`, the faucet tokens, the router a browser drives,
 * the x402 hook, a configured pool and enough liquidity to trade it.
 *
 * @dev A hook nobody can click is a blog post, and clicking one needs four things a fresh chain does not have. This
 * produces all of them in one run against `anvil`, so the front end can be exercised for real before anybody has
 * spent anything on a public network. The same script is what proves the UI works: if the payment modal signs
 * something this stack rejects, it fails here rather than on a chain where it costs money to find out.
 *
 *   anvil &
 *   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 *
 * The addresses are printed as JSON on the last line, which `web/local.json` is written from.
 */
contract DeployLocal is Script {
    uint160 internal constant GATE_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Held in storage rather than as locals: a script frame that carries every deployed address at once overflows
    // the stack, and splitting the function is a worse fix than not needing to.
    PoolManager internal manager;
    DemoUSDC internal usdc;
    DemoToken internal weth;
    DemoToken internal dai;
    DemoRouter internal router;
    X402GateHook internal gate;
    PoolKey internal key;

    /// @dev Configures the terms, creates the pool and seeds it. Split out of `run` to stay inside the stack limit.
    function _openPool(address deployer) private {
        (Currency currency0, Currency currency1) = address(weth) < address(dai)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(dai)))
            : (Currency.wrap(address(dai)), Currency.wrap(address(weth)));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(gate))
        });

        // Terms: pay one dollar for the discounted tier. 1.00% becomes 0.05%.
        gate.configure(
            key,
            X402GateHook.Terms({asset: address(usdc), payTo: deployer, price: 1e6, baseFee: 10_000, discountedFee: 500})
        );

        router.initialize(key, SQRT_PRICE_1_1);

        usdc.claim();
        weth.claim();
        dai.claim();
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 5e18, salt: bytes32(0)}),
            ""
        );
    }

    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        manager = new PoolManager(deployer);
        // The pool trades two eighteen-decimal tokens; the payment asset is separate and is the six-decimal
        // stablecoin, which is how x402 works in practice: you pay in dollars for access to whatever you are
        // trading. Pairing a six-decimal token against an eighteen-decimal one at a 1:1 price would need a
        // sqrtPrice twelve orders of magnitude away from par and would make every number on screen unreadable.
        usdc = new DemoUSDC();
        weth = new DemoToken("Hook Demo Ether", "hETH");
        dai = new DemoToken("Hook Demo Dollar", "hUSD");
        router = new DemoRouter(IPoolManager(address(manager)));

        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            GATE_FLAGS,
            type(X402GateHook).creationCode,
            abi.encode(IPoolManager(address(manager)))
        );
        gate = new X402GateHook{salt: salt}(IPoolManager(address(manager)));
        require(address(gate) == predicted, "hook landed at an unexpected address");

        _openPool(deployer);

        vm.stopBroadcast();

        console2.log("");
        console2.log("HOOKFORGE_LOCAL_JSON_BEGIN");
        console2.log(
            string.concat(
                '{"chainId":', vm.toString(block.chainid),
                ',"poolManager":"', vm.toString(address(manager)),
                '","router":"', vm.toString(address(router)),
                '","hook":"', vm.toString(address(gate)),
                '","usdc":"', vm.toString(address(usdc)),
                '","weth":"', vm.toString(address(weth)),
                '","dai":"', vm.toString(address(dai)),
                '","currency0":"', vm.toString(Currency.unwrap(key.currency0)),
                '","currency1":"', vm.toString(Currency.unwrap(key.currency1)),
                '","fee":', vm.toString(uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)),
                ',"tickSpacing":60}'
            )
        );
        console2.log("HOOKFORGE_LOCAL_JSON_END");
    }
}
