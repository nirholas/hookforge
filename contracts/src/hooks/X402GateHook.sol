// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ForgeFeeHook} from "../base/ForgeFeeHook.sol";
import {PoolConfigurable} from "../base/PoolConfigurable.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/**
 * @title X402GateHook
 * @notice Makes the pool an x402 resource server: a swapper that presents a signed x402 payment gets a cheaper fee on
 * that swap, and the payment settles atomically with the trade.
 *
 * @dev x402 is how autonomous agents already pay for things. An agent asks for a resource, gets back HTTP 402 with a
 * machine-readable price, signs an EIP-3009 authorization for that amount, retries with the signature in a header, and
 * the resource server settles it. Thousands of endpoints speak it and every agent framework has a client for it. What
 * nothing speaks it for is liquidity, which is odd, because a fee tier is exactly the kind of thing an agent would
 * want to buy: it is metered, it is worth different amounts to different callers, and the caller knows its own value
 * better than the venue does.
 *
 * The usual way to give one class of swapper a better price is to gate on what they *are*: hold this NFT, be on this
 * allowlist, pass this KYC check. Every one of those is a proxy for willingness to pay, maintained by hand, and wrong
 * at the edges. This hook gates on the thing itself. Pay the pool's posted price and the swap is cheaper. Do not, and
 * it is not. Nobody curates anything.
 *
 * Three properties fall out of doing this in the hook rather than over HTTP:
 *
 * The 402 challenge is on-chain. {quote} returns the same fields an x402 client reads out of a 402 response body:
 * scheme, network, amount, asset, recipient, resource, timeout. An agent discovers the price with one `eth_call`
 * against the pool it was already going to trade, with no endpoint to find, no server to be up, and no TLS.
 *
 * Payment and delivery are atomic, which over HTTP they are not. An x402 client that pays for an API call and then
 * receives a 500 has paid for nothing and must argue about a refund. Here the payment settles inside `beforeSwap`, so
 * if the swap reverts for any reason afterwards, slippage, liquidity, another hook, the payment reverts with it. The
 * failure mode that makes x402 awkward to build on does not exist in this direction.
 *
 * There is no facilitator. The x402 deployment model puts a trusted service between payer and resource server to
 * verify and broadcast the authorization. The pool can do both itself, because it is already a contract and the
 * payment is already an on-chain object, so the trusted third party is simply absent rather than decentralized.
 *
 * How the discount is applied matters. The fee this hook returns is an *LP* fee, so the discount is paid for by
 * liquidity providers taking less on that swap, and the payment is what compensates them. Providers are therefore
 * selling cheap execution for a fixed fee up front instead of a variable one on the back end, which is a trade they
 * can price: if the posted price is set below the fee revenue given up, the pool leaks, and setting it is the one
 * judgement the pool creator has to get right.
 *
 * Payments are pulled with `receiveWithAuthorization` rather than `transferWithAuthorization`. Both are EIP-3009 and
 * x402's own reference facilitator uses the latter, but the latter can be broadcast by anyone: a bystander could
 * submit the payer's authorization on its own, the payment would land, the nonce would burn, and the swap that the
 * payment was for would then revert with the payer out of pocket. Requiring `msg.sender == to` removes that.
 *
 * Unrecognised `hookData` is ignored rather than rejected. The payload is prefixed with {X402_PAYMENT_MAGIC}, and
 * anything that does not start with it is treated as "no payment offered" and charged the base fee. A pool that
 * reverted on hookData it did not understand would be untradeable through any router that puts its own data there,
 * which is most of them.
 *
 * @custom:slug x402-gate
 * @custom:family Agent-native
 * @custom:prior-art Fee discounts gated on NFT or token ownership, allowlists and KYC attestations are among the most common hook patterns, and x402 itself is a widely deployed HTTP payment protocol with an EIP-3009 settlement scheme. Neither has met the other: making an AMM pool an x402 resource server, so that the 402 challenge is an `eth_call` and settlement is atomic with the swap it paid for, is the contribution here.
 * @custom:limitation A payment costs a full EIP-3009 transfer, so the discount only repays its own gas above a swap size that depends on the chain and the spread between the two fee tiers. On a mainnet-priced chain that floor is high enough that this is a hook for agents moving real size, not for retail swaps. It also inherits the hookData problem: an aggregator that does not forward hookData cannot present a payment, and its users silently pay the base fee rather than getting an error telling them why.
 * @custom:chains base,arbitrum,unichain,robinhood,ethereum,optimism,polygon
 */
contract X402GateHook is ForgeFeeHook, PoolConfigurable {
    using SafeERC20 for IERC20;

    /// @notice The terms a pool posts. Set once, before the pool exists, and never changed.
    struct Terms {
        /// @notice The EIP-3009 token payments are denominated in. USDC on every chain x402 targets.
        address asset;
        /// @notice Where settled payments accrue, withdrawable by anyone but always paid to this address.
        address payTo;
        /// @notice The price of one discounted swap, in `asset` units. A payment below this is refused.
        uint256 price;
        /// @notice The fee charged to a swap that presents no payment.
        uint24 baseFee;
        /// @notice The fee charged to a swap that presents a valid one.
        uint24 discountedFee;
    }

    /**
     * @notice An x402 `exact`-scheme payment, as it arrives in `hookData`.
     * @dev These are the EIP-3009 authorization fields verbatim, which is what an x402 client already produces. `to`
     * is absent because it is always this hook, and including it would let a caller sign a payment to somewhere else
     * and present it here.
     */
    struct Payment {
        address from;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        bytes signature;
    }

    /**
     * @notice The on-chain form of an x402 402-response body.
     * @dev Field names track the x402 `PaymentRequirements` object so that a client can build its `X-PAYMENT` header
     * from this struct without a translation layer.
     */
    struct PaymentRequirements {
        string scheme;
        uint256 network;
        uint256 maxAmountRequired;
        address asset;
        address payTo;
        string resource;
        uint256 maxTimeoutSeconds;
    }

    /**
     * @notice Prefix identifying `hookData` as an x402 payment for this hook.
     * @dev Any `hookData` not starting with these four bytes is another integration's, and is ignored.
     */
    bytes4 public constant X402_PAYMENT_MAGIC = bytes4(keccak256("x402-exact-eip3009"));

    /// @notice The x402 scheme this hook settles. Only `exact` has an EIP-3009 binding.
    string public constant X402_SCHEME = "exact";

    /// @notice How long a quoted price should be treated as good for, in seconds. Advisory, for the client's `validBefore`.
    uint256 public constant QUOTE_TIMEOUT_SECONDS = 300;

    /// @notice Posted terms, per pool.
    mapping(PoolId => Terms) public termsOf;

    /// @notice Settled payments accrued for a pool and not yet withdrawn.
    mapping(PoolId => uint256) public collected;

    /// @dev A pool posted a discounted fee that is not below its base fee, so paying would buy nothing.
    error DiscountNotADiscount(uint24 baseFee, uint24 discountedFee);

    /// @dev Terms named the zero address as the payment asset or the payee.
    error InvalidTerms();

    /// @dev Terms posted a price of zero, which would make the discount free and the gate pointless.
    error PriceRequired();

    /// @dev The payment offered is smaller than the pool's posted price.
    error PaymentBelowPrice(uint256 offered, uint256 required);

    /// @dev There is nothing accrued for this pool to withdraw.
    error NothingCollected();

    /// @notice Emitted once per pool, when its terms are posted.
    event PoolConfigured(PoolId indexed id, address asset, address payTo, uint256 price, uint24 baseFee, uint24 discountedFee);

    /// @notice Emitted for every payment this hook settles.
    event PaymentSettled(PoolId indexed id, address indexed from, uint256 value, bytes32 nonce);

    /// @notice Emitted when accrued payments are swept to the pool's payee.
    event Withdrawn(PoolId indexed id, address indexed payTo, uint256 amount);

    constructor(IPoolManager _poolManager) ForgeFeeHook(_poolManager) {}

    /**
     * @notice Post the terms for a pool that does not exist yet.
     * @dev Permissionless and final, per {PoolConfigurable}. The pool must then be initialized with the dynamic-fee
     * flag, which {ForgeFeeHook} enforces on `afterInitialize`.
     */
    function configure(PoolKey calldata key, Terms calldata terms) external {
        if (terms.asset == address(0) || terms.payTo == address(0)) revert InvalidTerms();
        if (terms.price == 0) revert PriceRequired();
        if (terms.discountedFee >= terms.baseFee) revert DiscountNotADiscount(terms.baseFee, terms.discountedFee);
        FeeMath.requireValid(terms.baseFee);

        _requireUninitialized(key);
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        termsOf[id] = terms;
        emit PoolConfigured(id, terms.asset, terms.payTo, terms.price, terms.baseFee, terms.discountedFee);
    }

    /**
     * @notice The payment requirements for one discounted swap on `id`, in the shape an x402 client expects.
     * @dev This is the 402 challenge. A client reads it, signs an EIP-3009 authorization for `maxAmountRequired` of
     * `asset` to this hook, and passes {encodePayment}'s output as the swap's `hookData`.
     */
    function quote(PoolId id) external view returns (PaymentRequirements memory) {
        Terms memory terms = termsOf[id];
        if (terms.payTo == address(0)) revert PoolNotConfigured();

        return PaymentRequirements({
            scheme: X402_SCHEME,
            network: block.chainid,
            maxAmountRequired: terms.price,
            asset: terms.asset,
            payTo: address(this),
            resource: specURI(),
            maxTimeoutSeconds: QUOTE_TIMEOUT_SECONDS
        });
    }

    /// @notice The fee a swap on `id` would pay, with and without a payment.
    function feeTiers(PoolId id) external view returns (uint24 baseFee, uint24 discountedFee) {
        Terms memory terms = termsOf[id];
        if (terms.payTo == address(0)) revert PoolNotConfigured();
        return (terms.baseFee, terms.discountedFee);
    }

    /// @notice Wrap a payment into the `hookData` a swap must carry, magic prefix included.
    function encodePayment(Payment calldata payment) external pure returns (bytes memory) {
        return bytes.concat(X402_PAYMENT_MAGIC, abi.encode(payment));
    }

    /**
     * @notice Sweep a pool's accrued payments to the payee its terms named.
     * @dev Callable by anyone, because the destination is fixed at configuration time and cannot be redirected. That
     * keeps the payee from having to be an EOA that remembers to collect.
     */
    function withdraw(PoolId id) external {
        Terms memory terms = termsOf[id];
        if (terms.payTo == address(0)) revert PoolNotConfigured();

        uint256 amount = collected[id];
        if (amount == 0) revert NothingCollected();

        collected[id] = 0;
        IERC20(terms.asset).safeTransfer(terms.payTo, amount);
        emit Withdrawn(id, terms.payTo, amount);
    }

    /**
     * @dev Settle a payment if one was offered, and price the swap accordingly. A settlement failure, a bad
     * signature, an expired authorization, a spent nonce, an underfunded payer, reverts here and takes the swap with
     * it, which is the atomicity this hook exists for.
     */
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (uint24)
    {
        PoolId id = key.toId();
        Terms memory terms = termsOf[id];
        if (terms.payTo == address(0)) revert PoolNotConfigured();

        if (hookData.length < 4 || bytes4(hookData[:4]) != X402_PAYMENT_MAGIC) return terms.baseFee;

        Payment memory payment = abi.decode(hookData[4:], (Payment));
        if (payment.value < terms.price) revert PaymentBelowPrice(payment.value, terms.price);

        IERC3009(terms.asset).receiveWithAuthorization(
            payment.from,
            address(this),
            payment.value,
            payment.validAfter,
            payment.validBefore,
            payment.nonce,
            payment.signature
        );

        collected[id] += payment.value;
        emit PaymentSettled(id, payment.from, payment.value, payment.nonce);

        return terms.discountedFee;
    }

    /// @inheritdoc PoolConfigurable
    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function hookName() external pure override returns (string memory) {
        return "X402Gate";
    }

    function specURI() public pure override returns (string memory) {
        return string.concat(SPEC_BASE, "x402-gate.json");
    }

    function hookTags() external pure override returns (string[] memory tags) {
        tags = new string[](4);
        tags[0] = "agent-native";
        tags[1] = "x402";
        tags[2] = "dynamic-fee";
        tags[3] = "metering";
    }
}
