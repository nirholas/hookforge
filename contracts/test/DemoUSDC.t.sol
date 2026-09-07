// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoUSDC} from "src/demo/DemoUSDC.sol";

contract DemoUSDCTest is Test {
    DemoUSDC internal usdc;

    uint256 internal payerKey = 0xA11CE;
    address internal payer;
    address internal payee = address(0xBEEF);

    bytes32 private constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new DemoUSDC();
        payer = vm.addr(payerKey);
        usdc.claimTo(payer);
    }

    function _sign(uint256 value, bytes32 nonce, address to) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_TYPEHASH, payer, to, value, uint256(0), block.timestamp + 300, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_sixDecimalsLikeAStablecoin() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.balanceOf(payer), usdc.CLAIM_AMOUNT());
    }

    function test_faucetCoolsDown() public {
        assertGt(usdc.cooldownRemaining(payer), 0);
        vm.expectRevert();
        usdc.claimTo(payer);

        vm.warp(block.timestamp + usdc.COOLDOWN());
        usdc.claimTo(payer);
        assertEq(usdc.balanceOf(payer), 2 * usdc.CLAIM_AMOUNT());
    }

    function test_receiveWithAuthorizationPaysThePayee() public {
        bytes32 nonce = keccak256("one");
        bytes memory signature = _sign(100e6, nonce, payee);

        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, block.timestamp + 300, nonce, signature);

        assertEq(usdc.balanceOf(payee), 100e6);
        assertTrue(usdc.authorizationState(payer, nonce), "the nonce is spent");
    }

    function test_onlyThePayeeMaySubmitIt() public {
        // The property that makes x402 safe: a signed payment cannot be lifted and redirected, because only the
        // named recipient can submit it.
        bytes32 nonce = keccak256("two");
        bytes memory signature = _sign(100e6, nonce, payee);

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.CallerMustBePayee.selector, payee, address(0xDEAD)));
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, block.timestamp + 300, nonce, signature);
    }

    function test_aNonceIsSingleUse() public {
        bytes32 nonce = keccak256("three");
        bytes memory signature = _sign(100e6, nonce, payee);

        vm.startPrank(payee);
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, block.timestamp + 300, nonce, signature);
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.AuthorizationUsed.selector, payer, nonce));
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, block.timestamp + 300, nonce, signature);
        vm.stopPrank();
    }

    function test_anExpiredAuthorizationIsRefused() public {
        bytes32 nonce = keccak256("four");
        uint256 validBefore = block.timestamp + 300;
        bytes memory signature = _sign(100e6, nonce, payee);

        vm.warp(validBefore + 1);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.AuthorizationExpired.selector, validBefore));
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, validBefore, nonce, signature);
    }

    function test_aTamperedAmountIsRefused() public {
        bytes32 nonce = keccak256("five");
        bytes memory signature = _sign(100e6, nonce, payee);

        vm.prank(payee);
        vm.expectRevert(DemoUSDC.InvalidSignature.selector);
        usdc.receiveWithAuthorization(payer, payee, 200e6, 0, block.timestamp + 300, nonce, signature);
    }

    function test_cancellingBurnsTheNonce() public {
        bytes32 nonce = keccak256("six");
        bytes memory signature = _sign(100e6, nonce, payee);

        bytes32 cancelHash = keccak256(
            abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), payer, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), cancelHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        usdc.cancelAuthorization(payer, nonce, abi.encodePacked(r, s, v));

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.AuthorizationUsed.selector, payer, nonce));
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, block.timestamp + 300, nonce, signature);
    }
}
