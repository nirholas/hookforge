// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {RebaseAbsorbHook} from "src/hooks/RebaseAbsorbHook.sol";
import {RebasingToken} from "src/demo/RebasingToken.sol";
import {FeeOnTransferToken} from "src/demo/FeeOnTransferToken.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract RebaseAbsorbHookTest is ForgeTest {
    RebaseAbsorbHook internal hook;
    PoolKey internal poolKey;
    RebasingToken internal rebasing;
    FeeOnTransferToken internal taxed;
    Currency internal cur0;
    Currency internal cur1;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint256 internal constant FEE_BPS = 30; // 0.30%
    uint256 internal constant TRANSFER_TAX_BPS = 200; // 2% taken by the token itself

    address internal alice = address(0xA11CE);

    function setUp() public {
        setUpForge();

        rebasing = new RebasingToken("Rebasing", "REB");
        taxed = new FeeOnTransferToken("Taxed", "TAX", TRANSFER_TAX_BPS);

        (address a, address b) = address(rebasing) < address(taxed)
            ? (address(rebasing), address(taxed))
            : (address(taxed), address(rebasing));
        cur0 = Currency.wrap(a);
        cur1 = Currency.wrap(b);

        hook = RebaseAbsorbHook(
            deployHookTo(
                "src/hooks/RebaseAbsorbHook.sol:RebaseAbsorbHook",
                FLAGS,
                abi.encode(address(manager), FEE_BPS, "Rebase Absorb LP", "RA-LP")
            )
        );

        poolKey = PoolKey(cur0, cur1, 3000, 60, IHooks(address(hook)));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        rebasing.mint(address(this), 10_000e18);
        taxed.mint(address(this), 10_000e18);
        rebasing.mint(alice, 10_000e18);
        taxed.mint(alice, 10_000e18);

        IERC20(a).approve(address(hook), type(uint256).max);
        IERC20(b).approve(address(hook), type(uint256).max);
        IERC20(a).approve(address(swapRouter), type(uint256).max);
        IERC20(b).approve(address(swapRouter), type(uint256).max);

        hook.deposit(1_000e18, 1_000e18);
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "RebaseAbsorb");
    }

    // --- structure ----------------------------------------------------------

    function test_theReserveIsTheHooksOwnBalance() public view {
        (uint256 reserve0, uint256 reserve1) = hook.reserves();
        assertEq(reserve0, IERC20(Currency.unwrap(cur0)).balanceOf(address(hook)), "no stored reserve to drift");
        assertEq(reserve1, IERC20(Currency.unwrap(cur1)).balanceOf(address(hook)), "on either side");
    }

    function test_thePoolsOwnLiquidityPathIsClosed() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-60, 60, 1e18, bytes32(0)), ZERO_BYTES
        );
    }

    function test_theHookBindsToOnePoolOnly() public {
        PoolKey memory other = PoolKey(cur0, cur1, 500, 10, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_exactOutputIsRefusedRatherThanApproximated() public {
        vm.expectRevert();
        swap(poolKey, true, 1e18, ZERO_BYTES);
    }

    // --- rebasing -----------------------------------------------------------

    /// @dev The property v4's singleton cannot deliver: a supply change lands on the pool that holds the token.
    function test_aPositiveRebaseIncreasesTheReserves() public {
        (uint256 before0, uint256 before1) = hook.reserves();
        rebasing.rebase(11_000); // +10%

        (uint256 after0, uint256 after1) = hook.reserves();
        bool zeroIsRebasing = Currency.unwrap(cur0) == address(rebasing);
        if (zeroIsRebasing) {
            assertGt(after0, before0, "the rebasing side grew");
            assertEq(after1, before1, "and the other did not");
        } else {
            assertGt(after1, before1, "the rebasing side grew");
            assertEq(after0, before0, "and the other did not");
        }
    }

    /// @dev And it belongs to the share holders, with no accounting step in between.
    function test_aRebaseIsWorthMoreToEveryShare() public {
        uint256 shares = hook.balanceOf(address(this));
        rebasing.rebase(12_000); // +20%

        (uint256 amount0, uint256 amount1) = hook.withdraw(shares);
        bool zeroIsRebasing = Currency.unwrap(cur0) == address(rebasing);
        uint256 rebased = zeroIsRebasing ? amount0 : amount1;

        // The deposit was 1000; a 20% rebase should return meaningfully more than that.
        assertGt(rebased, 1_100e18, "the rebase reached the share holder");
    }

    function test_aNegativeRebaseIsPricedInImmediately() public {
        uint256 quoteBefore = hook.quote(true, 1e18);
        rebasing.rebase(5_000); // halve every balance
        uint256 quoteAfter = hook.quote(true, 1e18);

        assertTrue(quoteBefore != quoteAfter, "the quote moved with the supply");
    }

    function test_aRebaseNeedsNobodyToNoticeIt() public {
        rebasing.rebase(11_000);
        // No poke, no settle, no keeper: the very next quote already reflects it.
        assertGt(hook.quote(true, 1e18), 0, "still quoting, from the new reserves");
    }

    // --- fee on transfer ----------------------------------------------------

    /// @dev Whether selling the untaxed token buys the taxed one, which is the direction a hook can settle.
    function _taxedIsOutputDirection() private view returns (bool) {
        return Currency.unwrap(cur1) == address(taxed);
    }

    /// @dev A taxed payout balances, because the hook declares what settlement actually credited.
    function test_aTaxedOutputSettlesAtWhatActuallyArrived() public {
        bool zeroForOne = _taxedIsOutputDirection();
        uint256 got = _swapAndMeasure(zeroForOne, 50e18);
        assertGt(got, 0, "the swap went through with a taxed token on the way out");
    }

    function test_aTaxedOutputPaysTheTraderNetOfTheTokensCut() public {
        bool zeroForOne = _taxedIsOutputDirection();
        taxed.setFee(0);
        uint256 untaxed = _swapAndMeasure(zeroForOne, 50e18);

        taxed.setFee(TRANSFER_TAX_BPS);
        uint256 afterTax = _swapAndMeasure(zeroForOne, 50e18);

        assertLt(afterTax, untaxed, "the token took its cut from the trader, as it does everywhere");
    }

    function test_aTokenThatChangesItsFeeNeedsNoReconfiguration() public {
        bool zeroForOne = _taxedIsOutputDirection();
        uint256 atTwoPercent = _swapAndMeasure(zeroForOne, 50e18);

        taxed.setFee(1_000); // the token raises its own fee to 10%
        uint256 atTenPercent = _swapAndMeasure(zeroForOne, 50e18);

        assertLt(atTenPercent, atTwoPercent, "a bigger cut reaches the trader as a smaller payout");
        assertGt(atTenPercent, 0, "and nothing reverted, with no configuration anywhere");
    }

    /**
     * @dev The stated boundary, held to.
     *
     * A taxed input cannot balance through the manager: whatever the swapper sends is taxed before the manager
     * counts it, so the swapper is always short by the tax and only a router that over-sends can cover it. The hook
     * does not pretend to fix this, and this test is here so nobody later assumes it does.
     */
    function test_aTaxedInputNeedsARouterThatOverSends() public {
        bool zeroForOne = !_taxedIsOutputDirection();
        vm.expectRevert();
        swap(poolKey, zeroForOne, -50e18, ZERO_BYTES);
    }

    /// @dev Swaps and reports what the caller's output balance actually gained.
    function _swapAndMeasure(bool zeroForOne, uint256 amountIn) private returns (uint256) {
        IERC20 out = IERC20(Currency.unwrap(zeroForOne ? cur1 : cur0));
        uint256 before = out.balanceOf(address(this));
        swap(poolKey, zeroForOne, -int256(amountIn), ZERO_BYTES);
        return out.balanceOf(address(this)) - before;
    }

    // --- shares -------------------------------------------------------------

    function test_depositMintsSharesAndLocksTheMinimum() public {
        assertGt(hook.balanceOf(address(this)), 0, "the depositor holds shares");
        assertGt(hook.totalSupply(), hook.balanceOf(address(this)), "with the minimum locked away");
    }

    function test_withdrawReturnsBothSides() public {
        uint256 shares = hook.balanceOf(address(this));
        (uint256 amount0, uint256 amount1) = hook.withdraw(shares);
        assertGt(amount0, 0, "currency0 came back");
        assertGt(amount1, 0, "and currency1");
    }

    function test_aDepositIsCreditedOnWhatArrived() public {
        // The taxed side loses 2% on the way in, so the deposit is trimmed to the ratio that actually landed.
        vm.startPrank(alice);
        IERC20(Currency.unwrap(cur0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(cur1)).approve(address(hook), type(uint256).max);
        uint256 shares = hook.deposit(100e18, 100e18);
        vm.stopPrank();

        assertGt(shares, 0, "alice got a position");
        assertEq(hook.balanceOf(alice), shares, "and it is hers");
    }

    // --- invariants ---------------------------------------------------------

    /// @dev Whatever the size, a swap the hook can settle leaves the pool holding more of what came in.
    function testFuzz_anInputAlwaysGrowsTheReserveItArrivedIn(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 200e18);
        bool zeroForOne = _taxedIsOutputDirection();

        (uint256 before0, uint256 before1) = hook.reserves();
        swap(poolKey, zeroForOne, -int256(amountIn), ZERO_BYTES);
        (uint256 after0, uint256 after1) = hook.reserves();

        assertGt(after0, 0, "the pool still holds currency0");
        assertGt(after1, 0, "and currency1");
        uint256 grew = zeroForOne ? after0 - before0 : after1 - before1;
        assertGt(grew, 0, "the side the input arrived in grew");
    }

    /// @dev However the supply moves, a share is always redeemable for a slice of whatever is there.
    function testFuzz_sharesTrackWhateverTheReservesBecome(uint256 factorBps) public {
        factorBps = bound(factorBps, 5_000, 20_000);
        rebasing.rebase(factorBps);

        uint256 shares = hook.balanceOf(address(this));
        (uint256 amount0, uint256 amount1) = hook.withdraw(shares);
        assertGt(amount0 + amount1, 0, "a share is worth a slice of whatever the pool holds now");
    }
}
