// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VestedBuyHook} from "src/hooks/VestedBuyHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract VestedBuyHookTest is ForgeTest {
    VestedBuyHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint160 internal constant FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    uint16 internal constant IMMEDIATE = 2_000; // 20% now, 80% vested
    uint32 internal constant CLIFF = 7 days;
    uint32 internal constant DURATION = 30 days;
    uint64 internal endsAt;

    address internal buyer = address(0xB0B);

    function setUp() public {
        setUpForge();
        vm.warp(1_800_000_000);
        endsAt = uint64(block.timestamp + 14 days);

        hook = VestedBuyHook(deployHookTo("src/hooks/VestedBuyHook.sol:VestedBuyHook", FLAGS, abi.encode(address(manager))));

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();

        // currency1 is the token being launched, so buying it means selling currency0: zeroForOne.
        hook.configure(
            poolKey,
            VestedBuyHook.Config({
                buyIsZeroForOne: true,
                immediateBps: IMMEDIATE,
                cliff: CLIFF,
                duration: DURATION,
                endsAt: endsAt
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-60000, 60000, 1e19, bytes32(0)), ZERO_BYTES
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "VestedBuy");
    }

    function test_configure_rejectsBadParameters() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;

        vm.expectRevert(VestedBuyHook.InvalidShare.selector);
        hook.configure(
            other,
            VestedBuyHook.Config({buyIsZeroForOne: true, immediateBps: 20_000, cliff: CLIFF, duration: DURATION, endsAt: endsAt})
        );

        vm.expectRevert(VestedBuyHook.EndsInThePast.selector);
        hook.configure(
            other,
            VestedBuyHook.Config({
                buyIsZeroForOne: true,
                immediateBps: IMMEDIATE,
                cliff: CLIFF,
                duration: DURATION,
                endsAt: uint64(block.timestamp)
            })
        );
    }

    function test_aBuyDeliversTheImmediateShareAndVestsTheRest() public {
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        BalanceDelta delta = swap(poolKey, true, -1e17, abi.encode(address(this)));

        uint256 received = IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1;
        (uint128 total,,) = hook.grantOf(poolId, address(this));

        assertGt(total, 0, "the rest should have been vested");
        // The delta the swapper sees is already net of what the hook withheld.
        assertEq(uint256(uint128(delta.amount1())), received, "what arrived matches the reported delta");
        assertApproxEqRel(received * 4, uint256(total), 1e16, "20% now, 80% vested");
    }

    function test_nothingUnlocksBeforeTheCliff() public {
        swap(poolKey, true, -1e17, abi.encode(address(this)));
        assertEq(hook.claimable(poolId, address(this)), 0, "nothing before the cliff");

        vm.warp(block.timestamp + CLIFF - 1);
        assertEq(hook.claimable(poolId, address(this)), 0, "still nothing one second short of it");
    }

    function test_itUnlocksLinearlyAfterTheCliff() public {
        swap(poolKey, true, -1e17, abi.encode(address(this)));
        (uint128 total,,) = hook.grantOf(poolId, address(this));

        vm.warp(block.timestamp + CLIFF + DURATION / 2);
        assertApproxEqRel(hook.claimable(poolId, address(this)), uint256(total) / 2, 1e15, "half way through, half of it");

        vm.warp(block.timestamp + DURATION);
        assertEq(hook.claimable(poolId, address(this)), total, "and all of it at the end");
    }

    function test_claimingPaysRealTokensAndCannotBeRepeated() public {
        swap(poolKey, true, -1e17, abi.encode(address(this)));
        vm.warp(block.timestamp + CLIFF + DURATION);

        uint256 owed = hook.claimable(poolId, address(this));
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 got = hook.claim(poolKey, address(this));
        assertEq(got, owed);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before1, owed, "paid as real tokens");

        vm.expectRevert(VestedBuyHook.NothingVested.selector);
        hook.claim(poolKey, address(this));
    }

    function test_sellingIsNeverVested() public {
        // Only buys are vested. Selling the launched token back is an ordinary swap.
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        swap(poolKey, false, -1e17, ZERO_BYTES);
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), before0, "the sale paid out in full");

        (uint128 total,,) = hook.grantOf(poolId, address(this));
        assertEq(total, 0, "and vested nothing");
    }

    function test_anExactOutputBuyIsRefused() public {
        // The security property: v4 only lets a hook adjust the unspecified currency, which on an exact-output buy is
        // the input. Letting it through would make the vesting optional.
        vm.expectRevert();
        swap(poolKey, true, 1e16, abi.encode(address(this)));
    }

    function test_namingSomebodyElseGivesThemTheTokens() public {
        swap(poolKey, true, -1e17, abi.encode(buyer));

        (uint128 theirs,,) = hook.grantOf(poolId, buyer);
        (uint128 mine,,) = hook.grantOf(poolId, address(this));
        assertGt(theirs, 0, "the named account holds the grant");
        assertEq(mine, 0, "and the payer holds none");
    }

    function test_vestingStopsWhenTheWindowCloses() public {
        vm.warp(endsAt);
        assertFalse(hook.vestingActive(poolId), "the window should have closed");

        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swap(poolKey, true, -1e17, abi.encode(address(this)));

        (uint128 total,,) = hook.grantOf(poolId, address(this));
        assertEq(total, 0, "nothing vested once the window is closed");
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), before1, "the buy paid out in full");
    }

    function test_aSecondBuyRestartsTheScheduleForTheNewTokens() public {
        swap(poolKey, true, -1e17, abi.encode(address(this)));
        (, , uint64 firstStart) = hook.grantOf(poolId, address(this));

        vm.warp(block.timestamp + 1 days);
        swap(poolKey, true, -1e17, abi.encode(address(this)));
        (, , uint64 secondStart) = hook.grantOf(poolId, address(this));

        assertGt(secondStart, firstStart, "topping up does not backdate the new tokens");
    }

    function testFuzz_claimableNeverExceedsTheGrant(uint32 elapsed) public {
        swap(poolKey, true, -1e17, abi.encode(address(this)));
        (uint128 total,,) = hook.grantOf(poolId, address(this));

        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        assertLe(hook.claimable(poolId, address(this)), total, "never more than was vested");
        assertLe(hook.unlocked(poolId, address(this)), total);
    }
}
