// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title DemoUSDC
 * @notice A faucet stablecoin that implements EIP-3009, so the x402 payment flow can be exercised for real.
 *
 * @dev x402's `exact` scheme settles with EIP-3009 `receiveWithAuthorization`: the payer signs an authorization
 * off-chain, hands it to whoever is collecting, and the recipient submits it. That is what makes the scheme work
 * without an allowance and without the payer sending a transaction, and it is why USDC is what x402 is denominated
 * in almost everywhere.
 *
 * Demonstrating an x402 hook therefore needs a token that actually implements EIP-3009. A plain ERC-20 with a mock
 * bolted on would let the demo appear to work while proving nothing: the signature a real client produces is checked
 * against the token's own EIP-712 domain, and a stand-in that skips that check would accept signatures the real thing
 * rejects. So this is the real interface, with real domain separation and real single-use nonces.
 *
 * Two things it is not. It is not audited, and it is worthless: anyone may mint, subject to a cooldown, which is the
 * point of a faucet. And it is not USDC: it exists so a demo can be tried, and a production pool points at whatever
 * the chain's real stablecoin is.
 *
 * `receiveWithAuthorization` is the one that matters here. Unlike `transferWithAuthorization`, only the named
 * recipient can submit it, which is what stops a signed payment being lifted out of a pending transaction and
 * redirected. The x402 hook is always the recipient, so a payment signed for it cannot be spent anywhere else.
 */
contract DemoUSDC is ERC20, EIP712 {
    /// @notice How much a single claim mints. Six decimals, as dollar stablecoins use.
    uint256 public constant CLAIM_AMOUNT = 10_000e6;

    /// @notice How long an address must wait between claims.
    uint256 public constant COOLDOWN = 4 hours;

    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 private constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /// @notice Whether an authorizer has already used a nonce. EIP-3009 nonces are single use and never reset.
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    /// @notice When each address last claimed from the faucet.
    mapping(address => uint256) public lastClaimAt;

    /// @dev The authorization is not yet valid, or has expired.
    error AuthorizationNotYetValid(uint256 validAfter);
    error AuthorizationExpired(uint256 validBefore);

    /// @dev The nonce has already been used by this authorizer.
    error AuthorizationUsed(address authorizer, bytes32 nonce);

    /// @dev The signature does not recover to the named authorizer.
    error InvalidSignature();

    /// @dev `receiveWithAuthorization` may only be submitted by the payee named in the authorization.
    error CallerMustBePayee(address expected, address actual);

    /// @dev The faucet has a cooldown.
    error CooldownActive(uint256 secondsRemaining);

    event AuthorizationUsedEvent(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);
    event Claimed(address indexed to, uint256 amount);

    constructor() ERC20("Hook Demo USD Coin", "hUSDC") EIP712("Hook Demo USD Coin", "2") {}

    /// @notice Six decimals, matching the stablecoins x402 is denominated in.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint the claim amount to the caller.
    function claim() external {
        claimTo(msg.sender);
    }

    /// @notice Mint the claim amount to `to`. The cooldown is keyed on the recipient, not the caller.
    function claimTo(address to) public {
        uint256 last = lastClaimAt[to];
        // Cooldowns here are hours long; the seconds a proposer can shift cannot meaningfully move one.
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < last + COOLDOWN) {
            // forge-lint: disable-next-line(block-timestamp)
            revert CooldownActive(last + COOLDOWN - block.timestamp);
        }
        lastClaimAt[to] = block.timestamp;
        _mint(to, CLAIM_AMOUNT);
        emit Claimed(to, CLAIM_AMOUNT);
    }

    /// @notice Seconds until `account` may claim again.
    function cooldownRemaining(address account) external view returns (uint256) {
        uint256 last = lastClaimAt[account];
        if (last == 0) return 0;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 ready = last + COOLDOWN;
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp >= ready ? 0 : ready - block.timestamp;
    }

    /// @notice The EIP-712 domain separator, exposed so a client can verify what it is signing against.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Transfer on a signed authorization. Submittable by anyone.
     * @dev Present for completeness. x402's `exact` scheme uses {receiveWithAuthorization} instead, because this one
     * can be front-run: the signature is valid whoever submits it, so a payment signed for one purpose can be
     * broadcast by anybody for another.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _check(
            keccak256(
                abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
            ),
            from,
            validAfter,
            validBefore,
            nonce,
            signature
        );
        _transfer(from, to, value);
    }

    /**
     * @notice Transfer on a signed authorization, submittable only by the payee.
     * @dev The scheme x402 settles with. Requiring `msg.sender == to` is what stops a signed payment being lifted out
     * of a pending transaction and redirected, which is why a payment signed for a hook can only ever pay that hook.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (msg.sender != to) revert CallerMustBePayee(to, msg.sender);
        _check(
            keccak256(
                abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
            ),
            from,
            validAfter,
            validBefore,
            nonce,
            signature
        );
        _transfer(from, to, value);
    }

    /// @notice Burn an authorization the authorizer no longer wants honoured.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        if (authorizationState[authorizer][nonce]) revert AuthorizationUsed(authorizer, nonce);

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
        if (!SignatureChecker.isValidSignatureNow(authorizer, digest, signature)) revert InvalidSignature();

        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @dev Validates the window, the nonce and the signature, then burns the nonce.
    function _check(
        bytes32 structHash,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) private {
        // Authorization windows are set in minutes by the payer; proposer drift cannot meaningfully move them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid(validAfter);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= validBefore) revert AuthorizationExpired(validBefore);
        if (authorizationState[from][nonce]) revert AuthorizationUsed(from, nonce);

        // ERC-1271 as well as ECDSA, so a smart-account agent can pay too.
        if (!SignatureChecker.isValidSignatureNow(from, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }

        authorizationState[from][nonce] = true;
        emit AuthorizationUsedEvent(from, nonce);
    }
}
