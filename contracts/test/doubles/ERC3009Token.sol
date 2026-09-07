// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IERC3009} from "src/interfaces/IERC3009.sol";

/**
 * @title ERC3009Token
 * @notice A faithful EIP-3009 token for tests, matching USDC's `receiveWithAuthorization` semantics.
 * @dev This is a test double for the payment asset, not a stand-in for the mechanism under test: the authorization is
 * really signed, really recovered, and the nonce is really consumed, so a test that passes here would pass against
 * USDC. The rules enforced are EIP-3009's own: only `to` may submit, the authorization must be inside its validity
 * window, and a nonce is single use per authorizer.
 */
contract ERC3009Token is ERC20, EIP712, IERC3009 {
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @dev The caller is not the authorization's recipient.
    error CallerMustBePayee();

    /// @dev The authorization is not yet valid, or no longer is.
    error AuthorizationOutsideValidWindow();

    /// @dev This authorizer has already used this nonce.
    error AuthorizationAlreadyUsed();

    /// @dev The signature does not recover to `from`.
    error InvalidSignature();

    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    constructor() ERC20("Test USD Coin", "TUSDC") EIP712("Test USD Coin", "2") {}

    /// @inheritdoc IERC3009
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    /// @inheritdoc IERC3009
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (to != msg.sender) revert CallerMustBePayee();
        if (block.timestamp <= validAfter || block.timestamp >= validBefore) revert AuthorizationOutsideValidWindow();
        if (_authorizationStates[from][nonce]) revert AuthorizationAlreadyUsed();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidSignature();

        _authorizationStates[from][nonce] = true;
        _transfer(from, to, value);
    }

    /// @notice The EIP-712 digest a payer signs. Exposed so a test can sign without reimplementing the hash.
    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
    }

    /// @notice Fund an account for a test.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
