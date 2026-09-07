// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {ArbTaxDecayHook} from "src/hooks/ArbTaxDecayHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";

contract ArbTaxDecayHookTest is ForgeTest {
    ArbTaxDecayHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant BASE_FEE = 3000; // 0.30%
    uint24 internal constant MAX_SURCHARGE = 7000; // up to +0.70%, so 1.00% at full staleness
    uint32 internal constant HALF_LIFE = 300; // five quiet minutes buys half the surcharge

    function setUp() public {
        setUpForge();

        hook = ArbTaxDecayHook(
            deployHookTo(
                "src/hooks/ArbTaxDecayHook.sol:ArbTaxDecayHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, ArbTaxDecayHook.Config(BASE_FEE, MAX_SURCHARGE, HALF_LIFE));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "ArbTaxDecay");
    }

    function test_configuration_isStored() public view {
        (uint24 baseFee, uint24 maxSurcharge, uint32 halfLife) = hook.configOf(poolId);
        assertEq(baseFee, BASE_FEE);
        assertEq(maxSurcharge, MAX_SURCHARGE);
        assertEq(halfLife, HALF_LIFE);
    }

    function test_initialize_withoutConfiguration_reverts() public {
        PoolKey memory unconfigured =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PoolConfigurable.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(unconfigured, SQRT_PRICE_1_1);
    }

    function test_configure_afterInitialize_reverts() public {
        vm.expectRevert(PoolConfigurable.PoolAlreadyInitialized.selector);
        hook.configure(poolKey, ArbTaxDecayHook.Config(BASE_FEE, MAX_SURCHARGE, HALF_LIFE));
    }

    function test_configure_zeroHalfLife_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        vm.expectRevert(ArbTaxDecayHook.InvalidHalfLife.selector);
        hook.configure(other, ArbTaxDecayHook.Config(BASE_FEE, MAX_SURCHARGE, 0));
    }

    function test_configure_surchargeOverMaximum_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        vm.expectRevert(ArbTaxDecayHook.SurchargeTooLarge.selector);
        hook.configure(other, ArbTaxDecayHook.Config(500_000, 500_001, HALF_LIFE));
    }

    function test_freshPool_chargesBaseFee() public {
        // The staleness clock starts at initialization, and setUp does not warp, so the first swap is not stale.
        assertEq(hook.quoteFee(poolId), BASE_FEE);
        _expectFee(0, BASE_FEE);
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_halfLifeOfQuiet_chargesHalfTheSurcharge() public {
        vm.warp(block.timestamp + HALF_LIFE);
        assertEq(hook.quoteFee(poolId), BASE_FEE + MAX_SURCHARGE / 2);

        _expectFee(HALF_LIFE, BASE_FEE + MAX_SURCHARGE / 2);
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_swapResetsTheClock() public {
        vm.warp(block.timestamp + HALF_LIFE);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(hook.lastTradeAt(poolId), uint64(block.timestamp));

        // A second swap in the same second is ordinary flow, not arbitrage, and pays only the base fee.
        assertEq(hook.quoteFee(poolId), BASE_FEE);
        _expectFee(0, BASE_FEE);
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_surchargeIsCapped() public {
        vm.warp(block.timestamp + 3650 days);
        uint24 fee = hook.quoteFee(poolId);
        assertLt(fee, BASE_FEE + MAX_SURCHARGE, "saturating curve never reaches the cap");
        assertGt(fee, BASE_FEE + MAX_SURCHARGE - 10, "but gets arbitrarily close");
    }

    function test_stalerSwapCostsTheTraderMore() public {
        uint256 fresh = _amountOutForSwap(0);
        uint256 stale = _amountOutForSwap(HALF_LIFE);
        assertLt(stale, fresh, "a stale pool must quote worse to the arbitrageur");
    }

    function testFuzz_feeIsMonotoneAndBounded(uint32 elapsed) public {
        vm.warp(block.timestamp + elapsed);
        uint24 fee = hook.quoteFee(poolId);
        assertGe(fee, BASE_FEE);
        assertLe(fee, BASE_FEE + MAX_SURCHARGE);
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE);
    }

    function testFuzz_longerQuietNeverCostsLess(uint32 a, uint32 b) public {
        vm.assume(a < b);
        uint256 start = block.timestamp;

        vm.warp(start + a);
        uint24 feeA = hook.quoteFee(poolId);
        vm.warp(start + b);
        uint24 feeB = hook.quoteFee(poolId);

        assertGe(feeB, feeA);
    }

    /// @dev Asserts the next swap prices `elapsed` seconds of staleness at `fee`.
    /// @dev An override-fee hook supplies the fee per swap rather than storing it in the pool, so `slot0.lpFee` stays
    /// at zero and the hook's own event is the observable record of what was charged.
    function _expectFee(uint256 elapsed, uint24 fee) internal {
        vm.expectEmit(true, false, false, true, address(hook));
        emit ArbTaxDecayHook.StalenessPriced(poolId, elapsed, fee);
    }

    /// @dev Runs one swap `quietSeconds` after the pool last traded and returns the currency1 received, undoing state.
    function _amountOutForSwap(uint32 quietSeconds) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + quietSeconds);
        BalanceDelta delta = swap(poolKey, true, -1e15, ZERO_BYTES);
        out = uint256(uint128(delta.amount1()));
        vm.revertToState(snapshot);
    }
}
