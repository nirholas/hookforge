// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title IERC3009
 * @notice The transfer-authorization subset of EIP-3009 that x402's `exact` scheme settles with.
 *
 * @dev EIP-3009 lets a token holder sign a transfer off-chain and lets somebody else broadcast it, which is the whole
 * reason x402 can quote a price over HTTP and settle it on-chain without the payer ever sending a transaction. USDC
 * implements it on every chain x402 supports, and it is the only token standard the `exact` scheme requires.
 *
 * Only `receiveWithAuthorization` is declared here, deliberately. EIP-3009 also specifies
 * `transferWithAuthorization`, which anyone may broadcast; that openness is a front-running hazard when the
 * authorization is a precondition for something else, because a third party can burn the nonce by submitting the
 * transfer on its own and leave the payer having paid for nothing. `receiveWithAuthorization` requires
 * `msg.sender == to`, so only the intended recipient can pull the payment, which closes that hole.
 *
 * The `bytes signature` overload is used rather than the `(v, r, s)` one so that a payer may be a contract account
 * signing under ERC-1271. USDC has supported it since v2.2.
 */
interface IERC3009 {
    /**
     * @notice Pull a signed payment. Callable only by `to`.
     * @param from The payer, and the signer of the authorization.
     * @param to The recipient, which must be `msg.sender`.
     * @param value Amount to transfer, in the token's own units.
     * @param validAfter Timestamp the authorization becomes valid at.
     * @param validBefore Timestamp the authorization expires at.
     * @param nonce A unique 32-byte value chosen by the payer. Single use, per payer.
     * @param signature The payer's EIP-712 signature over the authorization, ECDSA or ERC-1271.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    /// @notice Whether `nonce` has already been used by `authorizer`. EIP-3009 nonces are single use and never reset.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}
