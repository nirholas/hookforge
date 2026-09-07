// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {X402GateHook} from "src/hooks/X402GateHook.sol";
import {PoolConfigurable} from "src/base/PoolConfigurable.sol";
import {ERC3009Token} from "./doubles/ERC3009Token.sol";
import {ForgeTest} from "./utils/ForgeTest.sol";

contract X402GateHookTest is ForgeTest {
    X402GateHook internal hook;
    ERC3009Token internal usdc;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal payerKey = 0xA11CE;
    uint256 internal strangerKey = 0xBAD;
    address internal payer;
    address internal payee = address(0xFEE);

    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant DISCOUNTED_FEE = 500;
    uint256 internal constant PRICE = 1e6;

    function setUp() public {
        setUpForge();

        payer = vm.addr(payerKey);
        usdc = new ERC3009Token();
        usdc.mint(payer, 1_000e6);

        hook = X402GateHook(
            deployHookTo(
                "src/hooks/X402GateHook.sol:X402GateHook",
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
                abi.encode(address(manager))
            )
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        hook.configure(poolKey, _terms());
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.warp(1_800_000_123);
    }

    function _terms() private view returns (X402GateHook.Terms memory) {
        return X402GateHook.Terms({
            asset: address(usdc),
            payTo: payee,
            price: PRICE,
            baseFee: BASE_FEE,
            discountedFee: DISCOUNTED_FEE
        });
    }

    /// @dev Builds the `hookData` for a swap that presents a payment, signing the EIP-3009 authorization for real.
    function _payment(uint256 value, bytes32 nonce, uint256 signerKey) private view returns (bytes memory) {
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        bytes32 digest =
            usdc.authorizationDigest(payer, address(hook), value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        return hook.encodePayment(
            X402GateHook.Payment({
                from: payer,
                value: value,
                validAfter: validAfter,
                validBefore: validBefore,
                nonce: nonce,
                signature: abi.encodePacked(r, s, v)
            })
        );
    }

    function _paid(bytes32 nonce) private view returns (bytes memory) {
        return _payment(PRICE, nonce, payerKey);
    }

    function _expectHookRevert(bytes memory inner) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_metadata() public view {
        assertMetadata(address(hook), "X402Gate");
    }

    function test_quote_answersTheX402ChallengeOnChain() public view {
        X402GateHook.PaymentRequirements memory req = hook.quote(poolId);

        assertEq(req.scheme, "exact", "x402 exact scheme");
        assertEq(req.network, block.chainid, "network is the chain id");
        assertEq(req.maxAmountRequired, PRICE, "price");
        assertEq(req.asset, address(usdc), "asset");
        assertEq(req.payTo, address(hook), "payments are pulled by the hook itself");
        assertGt(bytes(req.resource).length, 0, "resource URI");
        assertGt(req.maxTimeoutSeconds, 0, "timeout");
    }

    function test_swapWithoutPayment_paysTheBaseFee() public {
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertEq(usdc.balanceOf(address(hook)), 0, "no payment should have settled");
        assertEq(hook.collected(poolId), 0, "nothing accrued");
    }

    /// @dev The property that matters: paying changes what the swapper actually receives, not just a view function.
    function test_payingBuysABetterPrice() public {
        uint256 snap = vm.snapshotState();

        BalanceDelta unpaid = swap(poolKey, true, -1e15, ZERO_BYTES);
        int128 receivedUnpaid = unpaid.amount1();

        vm.revertToState(snap);

        BalanceDelta paid = swap(poolKey, true, -1e15, _paid(bytes32(uint256(1))));
        int128 receivedPaid = paid.amount1();

        assertGt(receivedPaid, receivedUnpaid, "a paid swap must return more than an unpaid one");

        // And the difference is the fee spread, not noise: 0.30% versus 0.05% on the same input.
        uint256 gain = uint256(uint128(receivedPaid - receivedUnpaid));
        uint256 expected = (uint256(uint128(receivedUnpaid)) * (BASE_FEE - DISCOUNTED_FEE)) / 1e6;
        assertApproxEqRel(gain, expected, 0.01e18, "the gain should be the spread between the two fee tiers");
    }

    function test_paidSwap_settlesThePaymentAndAccruesIt() public {
        uint256 payerBefore = usdc.balanceOf(payer);

        swap(poolKey, true, -1e15, _paid(bytes32(uint256(1))));

        assertEq(usdc.balanceOf(payer), payerBefore - PRICE, "payer should have paid exactly the posted price");
        assertEq(usdc.balanceOf(address(hook)), PRICE, "the hook holds the payment until it is swept");
        assertEq(hook.collected(poolId), PRICE, "accrued against the pool that earned it");
    }

    function test_unrelatedHookData_isIgnoredRatherThanRejected() public {
        // A router that puts its own data in hookData must not brick the pool.
        swap(poolKey, true, -1e15, abi.encode(uint256(12345), address(this)));
        assertEq(hook.collected(poolId), 0, "no payment was offered, so none should settle");
    }

    function test_paymentBelowThePostedPrice_reverts() public {
        bytes memory data = _payment(PRICE - 1, bytes32(uint256(1)), payerKey);
        _expectHookRevert(
            abi.encodeWithSelector(X402GateHook.PaymentBelowPrice.selector, PRICE - 1, PRICE)
        );
        swap(poolKey, true, -1e15, data);
    }

    function test_paymentSignedByAStranger_reverts() public {
        bytes memory data = _payment(PRICE, bytes32(uint256(1)), strangerKey);
        _expectHookRevert(abi.encodeWithSelector(ERC3009Token.InvalidSignature.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_replayedAuthorization_reverts() public {
        bytes memory data = _paid(bytes32(uint256(7)));
        swap(poolKey, true, -1e15, data);

        _expectHookRevert(abi.encodeWithSelector(ERC3009Token.AuthorizationAlreadyUsed.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_expiredAuthorization_reverts() public {
        bytes memory data = _paid(bytes32(uint256(1)));
        vm.warp(block.timestamp + 2 hours);

        _expectHookRevert(abi.encodeWithSelector(ERC3009Token.AuthorizationOutsideValidWindow.selector));
        swap(poolKey, true, -1e15, data);
    }

    function test_underfundedPayer_revertsAndTakesTheSwapWithIt() public {
        // The atomicity claim: settlement happens in `beforeSwap`, so a payment that cannot clear stops the trade.
        uint256 balance = usdc.balanceOf(payer);
        vm.prank(payer);
        usdc.transfer(address(0xDEAD), balance);

        uint256 currencyBefore = poolKey.currency0.balanceOf(address(this));
        bytes memory data = _paid(bytes32(uint256(1)));

        vm.expectRevert();
        swap(poolKey, true, -1e15, data);

        assertEq(poolKey.currency0.balanceOf(address(this)), currencyBefore, "a failed payment must not move the pool");
        assertEq(hook.collected(poolId), 0, "and must accrue nothing");
        assertFalse(usdc.authorizationState(payer, bytes32(uint256(1))), "and must not burn the nonce");
    }

    function test_withdraw_sweepsToThePayeeTheTermsNamed() public {
        swap(poolKey, true, -1e15, _paid(bytes32(uint256(1))));

        // Permissionless on purpose: the destination is fixed, so anyone may trigger the sweep.
        vm.prank(address(0xB0B));
        hook.withdraw(poolId);

        assertEq(usdc.balanceOf(payee), PRICE, "the payee receives the payment");
        assertEq(usdc.balanceOf(address(hook)), 0, "the hook keeps nothing");
        assertEq(hook.collected(poolId), 0, "accrual is cleared");
    }

    function test_withdraw_withNothingCollected_reverts() public {
        vm.expectRevert(X402GateHook.NothingCollected.selector);
        hook.withdraw(poolId);
    }

    function test_configure_rejectsADiscountThatIsNotOne() public {
        PoolKey memory fresh = poolKey;
        fresh.tickSpacing = 30;

        X402GateHook.Terms memory terms = _terms();
        terms.discountedFee = BASE_FEE;

        vm.expectRevert(
            abi.encodeWithSelector(X402GateHook.DiscountNotADiscount.selector, BASE_FEE, BASE_FEE)
        );
        hook.configure(fresh, terms);
    }

    function test_configure_rejectsAFreeGate() public {
        PoolKey memory fresh = poolKey;
        fresh.tickSpacing = 30;

        X402GateHook.Terms memory terms = _terms();
        terms.price = 0;

        vm.expectRevert(X402GateHook.PriceRequired.selector);
        hook.configure(fresh, terms);
    }

    function test_configure_rejectsZeroAddresses() public {
        PoolKey memory fresh = poolKey;
        fresh.tickSpacing = 30;

        X402GateHook.Terms memory terms = _terms();
        terms.asset = address(0);

        vm.expectRevert(X402GateHook.InvalidTerms.selector);
        hook.configure(fresh, terms);
    }

    function test_configure_afterThePoolExists_reverts() public {
        vm.expectRevert(PoolConfigurable.PoolAlreadyInitialized.selector);
        hook.configure(poolKey, _terms());
    }

    function test_quote_onAnUnconfiguredPool_reverts() public {
        vm.expectRevert(PoolConfigurable.PoolNotConfigured.selector);
        hook.quote(PoolId.wrap(keccak256("nobody configured this")));
    }

    function test_feeTiers_reportsBothSides() public view {
        (uint24 base, uint24 discounted) = hook.feeTiers(poolId);
        assertEq(base, BASE_FEE, "base");
        assertEq(discounted, DISCOUNTED_FEE, "discounted");
        assertLt(discounted, base, "paying must always be worth something");
    }

    function test_aPoolWithoutTheDynamicFeeFlag_cannotBeInitialized() public {
        PoolKey memory fixedFee = poolKey;
        fixedFee.tickSpacing = 30;
        fixedFee.fee = 3000;

        hook.configure(fixedFee, _terms());

        vm.expectRevert();
        manager.initialize(fixedFee, SQRT_PRICE_1_1);
    }

    function testFuzz_anyPaymentAtOrAboveThePriceIsAccepted(uint96 offered, uint96 nonceSeed) public {
        uint256 value = bound(offered, PRICE, 100e6);
        bytes32 nonce = bytes32(uint256(bound(nonceSeed, 1, type(uint96).max)));

        swap(poolKey, true, -1e15, _payment(value, nonce, payerKey));

        assertEq(hook.collected(poolId), value, "the pool accrues whatever was actually paid, not just the minimum");
    }
}
