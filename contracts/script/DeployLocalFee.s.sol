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

import {DemoToken} from "src/demo/DemoToken.sol";
import {DemoRouter} from "src/demo/DemoRouter.sol";
import {ArbTaxDecayHook} from "src/hooks/ArbTaxDecayHook.sol";

/**
 * @title DeployLocalFee
 * @notice Brings up a staleness-taxed pool on a local chain, so its demo panel can be exercised for real.
 *
 * @dev Separate from `DeployLocal` rather than one script deploying everything, because a script that deployed
 * twenty hooks would fail as a unit and take the whole demo with it whenever any one of them changed. Each of these
 * stands up one pool and prints the config its page reads.
 */
contract DeployLocalFee is Script {
    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager internal manager;
    DemoToken internal weth;
    DemoToken internal dai;
    DemoRouter internal router;
    ArbTaxDecayHook internal hook;
    PoolKey internal key;

    function run() external {
        vm.startBroadcast();

        manager = new PoolManager(msg.sender);
        weth = new DemoToken("Hook Demo Ether", "hETH");
        dai = new DemoToken("Hook Demo Dollar", "hUSD");
        router = new DemoRouter(IPoolManager(address(manager)));

        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, FLAGS, type(ArbTaxDecayHook).creationCode, abi.encode(IPoolManager(address(manager)))
        );
        hook = new ArbTaxDecayHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == predicted, "hook landed at an unexpected address");

        _openPool();

        vm.stopBroadcast();

        console2.log("HOOKFORGE_LOCAL_JSON_BEGIN");
        console2.log(
            string.concat(
                '{"poolManager":"', vm.toString(address(manager)),
                '","router":"', vm.toString(address(router)),
                '","hook":"', vm.toString(address(hook)),
                '","currency0":"', vm.toString(Currency.unwrap(key.currency0)),
                '","currency1":"', vm.toString(Currency.unwrap(key.currency1)),
                '"}'
            )
        );
        console2.log("HOOKFORGE_LOCAL_JSON_END");
    }

    function _openPool() private {
        (Currency currency0, Currency currency1) = address(weth) < address(dai)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(dai)))
            : (Currency.wrap(address(dai)), Currency.wrap(address(weth)));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // 0.05% for flow that arrives while the pool is fresh, up to 1.00% after a long silence, half of that
        // surcharge reached at ten minutes.
        hook.configure(key, ArbTaxDecayHook.Config({baseFee: 500, maxSurcharge: 9_500, halfLife: 600}));

        router.initialize(key, SQRT_PRICE_1_1);

        weth.claim();
        dai.claim();
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 5e18, salt: bytes32(0)}), ""
        );
    }
}
