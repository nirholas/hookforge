// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ForgeTest} from "./utils/ForgeTest.sol";
import {OracleBandHook} from "src/hooks/OracleBandHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";

/// @dev A price source under the test's direct control, so the band can be exercised from both sides.
contract SettableOracle is IPriceOracle {
    uint160 public price;
    uint256 public publishedAt;

    constructor(uint160 _price) {
        price = _price;
        publishedAt = block.timestamp;
    }

    function set(uint160 _price) external {
        price = _price;
        publishedAt = block.timestamp;
    }

    function setPublishedAt(uint256 _publishedAt) external {
        publishedAt = _publishedAt;
    }

    function sqrtPriceX96() external view returns (uint160, uint256) {
        return (price, publishedAt);
    }
}

contract OracleBandHookTest is ForgeTest {
    OracleBandHook internal hook;
    SettableOracle internal oracle;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint32 internal constant MAX_DEVIATION_BPS = 200; // two percent
    uint32 internal constant MAX_STALENESS = 3600;

    function setUp() public {
        vm.warp(1_800_000_000);
        setUpForge();

        oracle = new SettableOracle(SQRT_PRICE_1_1);
        hook = OracleBandHook(
            deployHookTo(
                "src/hooks/OracleBandHook.sol:OracleBandHook",
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG),
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        hook.configure(poolKey, OracleBandHook.Config(IPriceOracle(address(oracle)), MAX_DEVIATION_BPS, MAX_STALENESS));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    /// @dev An external entry point so a test can `try` a swap that is expected to be refused some of the time.
    function doSwap(bool zeroForOne, int256 amountSpecified) external {
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function _wrapped(bytes4 selector, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "OracleBand");
    }

    function test_atTheReference_deviationIsZero() public view {
        (uint256 deviationBps, bool withinBand) = hook.deviation(poolId);
        assertEq(deviationBps, 0);
        assertTrue(withinBand);
    }

    function test_initialize_outsideTheBand_reverts() public {
        // A second pool whose opening price is far from the reference must not be creatable.
        PoolKey memory other = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));
        hook.configure(other, OracleBandHook.Config(IPriceOracle(address(oracle)), MAX_DEVIATION_BPS, MAX_STALENESS));

        uint160 farPrice = uint160(uint256(SQRT_PRICE_1_1) * 2); // four times the price
        vm.expectRevert();
        manager.initialize(other, farPrice);
    }

    function test_initialize_withoutConfiguration_reverts() public {
        PoolKey memory unconfigured = PoolKey(currency0, currency1, 3000, 200, IHooks(address(hook)));
        vm.expectRevert(
            _wrapped(IHooks.afterInitialize.selector, abi.encodeWithSelector(PoolConfigurable.PoolNotConfigured.selector))
        );
        manager.initialize(unconfigured, SQRT_PRICE_1_1);
    }

    function test_configure_missingOracle_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, 3000, 120, IHooks(address(hook)));
        vm.expectRevert(OracleBandHook.InvalidConfig.selector);
        hook.configure(other, OracleBandHook.Config(IPriceOracle(address(0)), MAX_DEVIATION_BPS, MAX_STALENESS));
    }

    function test_swapInsideTheBand_succeeds() public {
        swap(poolKey, true, -1e14, ZERO_BYTES);
        (uint256 deviationBps, bool withinBand) = hook.deviation(poolId);
        assertLe(deviationBps, MAX_DEVIATION_BPS);
        assertTrue(withinBand);
    }

    function test_swapThatWouldLeaveTheBand_reverts() public {
        // Large enough to walk the pool well past two percent. The afterSwap check refuses to leave it there.
        vm.expectRevert();
        swap(poolKey, true, -5e18, ZERO_BYTES);
    }

    function test_splittingTheSwapDoesNotDefeatTheBand() public {
        // The constraint is on the resulting price, not on the size of any one trade, so smaller bites hit the same
        // wall rather than walking through it.
        for (uint256 i = 0; i < 40; i++) {
            (uint256 deviationBps,) = hook.deviation(poolId);
            if (deviationBps > MAX_DEVIATION_BPS / 2) break;
            try this.doSwap(true, -2e16) {}
            catch {
                break;
            }
        }

        (uint256 finalDeviation, bool withinBand) = hook.deviation(poolId);
        assertLe(finalDeviation, MAX_DEVIATION_BPS, "the pool never ends up outside its band");
        assertTrue(withinBand);
    }

    function test_referenceMovingAwayHaltsSwapping() public {
        // Nothing happened to the pool; the world moved. The pool declines to trade until it is back in line.
        oracle.set(uint160(uint256(SQRT_PRICE_1_1) * 3 / 2)); // reference price up 2.25x

        (uint256 deviationBps, bool withinBand) = hook.deviation(poolId);
        assertGt(deviationBps, MAX_DEVIATION_BPS);
        assertFalse(withinBand);

        vm.expectRevert();
        swap(poolKey, true, -1e14, ZERO_BYTES);
    }

    function test_staleReferenceHaltsSwapping() public {
        oracle.setPublishedAt(block.timestamp - MAX_STALENESS - 1);

        vm.expectRevert();
        swap(poolKey, true, -1e14, ZERO_BYTES);
    }

    function test_freshReferenceResumesSwapping() public {
        oracle.setPublishedAt(block.timestamp - MAX_STALENESS - 1);
        vm.expectRevert();
        swap(poolKey, true, -1e14, ZERO_BYTES);

        oracle.set(SQRT_PRICE_1_1);
        swap(poolKey, true, -1e14, ZERO_BYTES);
    }

    function test_liquidityCanLeaveWhileTheBandRefusesSwaps() public {
        oracle.set(uint160(uint256(SQRT_PRICE_1_1) * 3 / 2));

        vm.expectRevert();
        swap(poolKey, true, -1e14, ZERO_BYTES);

        // The property that makes a band safe to sit behind: it never traps anyone.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-12000, 12000, -5e18, bytes32(0)), ZERO_BYTES
        );
    }

    function testFuzz_deviationIsSymmetricAroundTheReference(uint96 factor) public {
        factor = uint96(bound(factor, 1.01e18, 1.5e18));

        oracle.set(uint160(uint256(SQRT_PRICE_1_1) * factor / 1e18));
        (uint256 up,) = hook.deviation(poolId);

        oracle.set(uint160(uint256(SQRT_PRICE_1_1) * 1e18 / factor));
        (uint256 down,) = hook.deviation(poolId);

        assertGt(up, 0);
        assertGt(down, 0);
    }
}
