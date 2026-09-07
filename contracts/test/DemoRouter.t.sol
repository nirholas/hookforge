// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DemoRouter} from "src/demo/DemoRouter.sol";
import {DemoToken} from "src/demo/DemoToken.sol";
import {ArbTaxDecayHook} from "src/hooks/ArbTaxDecayHook.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract DemoRouterTest is ForgeTest {
    DemoRouter internal router;
    DemoToken internal tokenA;
    DemoToken internal tokenB;
    ArbTaxDecayHook internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal alice = address(0xA11CE);

    int24 internal constant LOWER = -6000;
    int24 internal constant UPPER = 6000;

    function setUp() public {
        setUpForge();
        router = new DemoRouter(manager);

        // Two faucet tokens, sorted the way v4 requires.
        DemoToken first = new DemoToken("Hook Demo USD", "hUSD");
        DemoToken second = new DemoToken("Hook Demo ETH", "hETH");
        (tokenA, tokenB) = address(first) < address(second) ? (first, second) : (second, first);

        hook = ArbTaxDecayHook(
            deployHookTo(
                "src/hooks/ArbTaxDecayHook.sol:ArbTaxDecayHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
                abi.encode(address(manager))
            )
        );

        key_ = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id_ = key_.toId();

        hook.configure(key_, ArbTaxDecayHook.Config({baseFee: 500, maxSurcharge: 9500, halfLife: 600}));
        router.initialize(key_, SQRT_PRICE_1_1);

        // Fund this test contract and Alice through the faucet, and approve the router as a user would.
        tokenA.claim();
        tokenB.claim();
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        tokenA.claimTo(alice);
        tokenB.claimTo(alice);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();

        _addLiquidity(1e18);
    }

    function _addLiquidity(int256 amount) private returns (BalanceDelta) {
        return router.modifyLiquidity(
            key_, ModifyLiquidityParams({tickLower: LOWER, tickUpper: UPPER, liquidityDelta: amount, salt: bytes32(0)}), ""
        );
    }

    function _routerHoldsNothing() private view {
        assertEq(tokenA.balanceOf(address(router)), 0, "router held currency0 after the call");
        assertEq(tokenB.balanceOf(address(router)), 0, "router held currency1 after the call");
    }

    function test_initialize_createsThePool() public view {
        assertGt(poolSqrtPrice(key_), 0, "pool should exist");
    }

    function test_addLiquidity_pullsBothTokens_andRouterKeepsNothing() public {
        uint256 beforeA = tokenA.balanceOf(address(this));
        uint256 beforeB = tokenB.balanceOf(address(this));

        _addLiquidity(1e18);

        assertLt(tokenA.balanceOf(address(this)), beforeA, "currency0 should have been pulled");
        assertLt(tokenB.balanceOf(address(this)), beforeB, "currency1 should have been pulled");
        _routerHoldsNothing();
    }

    function test_swap_pullsInput_sendsOutput_andRouterKeepsNothing() public {
        vm.startPrank(alice);
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeB = tokenB.balanceOf(alice);

        BalanceDelta delta = router.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );
        vm.stopPrank();

        assertEq(tokenA.balanceOf(alice), beforeA - 1e15, "exactly the input should have left");
        assertGt(tokenB.balanceOf(alice), beforeB, "output should have arrived");
        assertEq(uint256(uint128(delta.amount1())), tokenB.balanceOf(alice) - beforeB, "delta should match the transfer");
        _routerHoldsNothing();
    }

    function test_removeLiquidity_returnsTokens_andRouterKeepsNothing() public {
        uint256 beforeA = tokenA.balanceOf(address(this));
        uint256 beforeB = tokenB.balanceOf(address(this));

        _addLiquidity(-5e17);

        assertGt(tokenA.balanceOf(address(this)), beforeA, "currency0 should have come back");
        assertGt(tokenB.balanceOf(address(this)), beforeB, "currency1 should have come back");
        _routerHoldsNothing();
    }

    function test_swap_reachesTheHook() public {
        // The hook prices staleness, so the same swap must cost more after the pool has sat quiet. If hookData and
        // the hook call were not reaching it through this router, both swaps would cost the same.
        vm.prank(alice);
        BalanceDelta fresh =
            router.swap(key_, SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), "");

        vm.warp(block.timestamp + 2400);

        vm.prank(alice);
        BalanceDelta stale =
            router.swap(key_, SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), "");

        assertLt(stale.amount1(), fresh.amount1(), "the hook's staleness fee should reach a swap made through the router");
    }

    function test_unlockCallback_fromAnyoneElse_reverts() public {
        vm.expectRevert(DemoRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    function test_swapWithoutApproval_reverts() public {
        address bob = address(0xB0B);
        tokenA.claimTo(bob);

        vm.prank(bob);
        vm.expectRevert();
        router.swap(key_, SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), "");
    }

    function test_faucet_mintsOnceThenCoolsDown() public {
        address carol = address(0xCAF3);
        tokenA.claimTo(carol);
        assertEq(tokenA.balanceOf(carol), tokenA.CLAIM_AMOUNT());
        assertGt(tokenA.cooldownRemaining(carol), 0);

        vm.expectRevert();
        tokenA.claimTo(carol);

        vm.warp(block.timestamp + tokenA.COOLDOWN());
        assertEq(tokenA.cooldownRemaining(carol), 0);
        tokenA.claimTo(carol);
        assertEq(tokenA.balanceOf(carol), 2 * tokenA.CLAIM_AMOUNT());
    }

    function testFuzz_routerNeverRetainsValue(uint96 amount, bool zeroForOne) public {
        uint256 size = bound(amount, 1e10, 1e16);

        vm.prank(alice);
        router.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(size),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            ""
        );
        _routerHoldsNothing();
    }
}
