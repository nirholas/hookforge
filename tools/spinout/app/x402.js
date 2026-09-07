/**
 * The x402 payment flow, done properly.
 *
 * x402 settles with EIP-3009 `receiveWithAuthorization`: the payer signs an authorization off-chain and hands it to
 * whoever is collecting, who submits it. Nothing is approved in advance and the payer sends no transaction of their
 * own, which is exactly why agents can use it.
 *
 * Two details are easy to get wrong and expensive to get wrong.
 *
 * The signature is checked against the *token's* EIP-712 domain, not the hook's, so the domain has to come from the
 * token. Where the token implements ERC-5267 that is one call; where it does not, the name is read and the version
 * has to be guessed, and the guess is verified against the token's own `DOMAIN_SEPARATOR` before anything is signed.
 * Signing first and discovering the mismatch on-chain wastes the visitor's gas to learn something a read could have
 * told us.
 *
 * And `to` must be the hook. `receiveWithAuthorization` refuses any submitter that is not the named payee, which is
 * what stops a signed payment being lifted out of a pending transaction and spent somewhere else. The hook signs
 * nothing and holds no key; it simply is the only address that can present the authorization.
 */
import {encodeAbiParameters, keccak256, parseAbiParameters, toHex, concatHex} from "viem";

/** `bytes4(keccak256("x402-exact-eip3009"))`, the prefix the hook looks for in `hookData`. */
export const X402_MAGIC = keccak256(toHex("x402-exact-eip3009")).slice(0, 10);

const RECEIVE_TYPES = {
  ReceiveWithAuthorization: [
    {name: "from", type: "address"},
    {name: "to", type: "address"},
    {name: "value", type: "uint256"},
    {name: "validAfter", type: "uint256"},
    {name: "validBefore", type: "uint256"},
    {name: "nonce", type: "bytes32"},
  ],
};

const DOMAIN_ABI = [
  {
    type: "function",
    name: "eip712Domain",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {type: "bytes1"}, {type: "string"}, {type: "string"}, {type: "uint256"},
      {type: "address"}, {type: "bytes32"}, {type: "uint256[]"},
    ],
  },
  {type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
  {type: "function", name: "DOMAIN_SEPARATOR", stateMutability: "view", inputs: [], outputs: [{type: "bytes32"}]},
  {type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{type: "uint8"}]},
  {type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256"}],
  },
];

/** The EIP-712 domain separator for a set of fields, computed the way the standard defines it. */
function separatorFor({name, version, chainId, verifyingContract}) {
  const typeHash = keccak256(
    toHex("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
  );
  return keccak256(
    encodeAbiParameters(parseAbiParameters("bytes32, bytes32, bytes32, uint256, address"), [
      typeHash,
      keccak256(toHex(name)),
      keccak256(toHex(version)),
      BigInt(chainId),
      verifyingContract,
    ]),
  );
}

/**
 * Works out the token's EIP-712 domain and proves it before anything is signed.
 *
 * ERC-5267 answers directly. Without it, the version is guessed from the handful real stablecoins use and each guess
 * is checked against the token's published `DOMAIN_SEPARATOR`, so a wrong guess is caught here rather than as a
 * failed transaction.
 */
export async function resolveDomain(client, token, chainId) {
  try {
    const result = await client.readContract({address: token, abi: DOMAIN_ABI, functionName: "eip712Domain"});
    const domain = {name: result[1], version: result[2], chainId: Number(result[3]), verifyingContract: result[4]};
    return {domain, verified: true, how: "ERC-5267"};
  } catch {
    // Not ERC-5267. Fall through to reading the name and testing versions against the published separator.
  }

  const name = await client.readContract({address: token, abi: DOMAIN_ABI, functionName: "name"});
  let published = null;
  try {
    published = await client.readContract({address: token, abi: DOMAIN_ABI, functionName: "DOMAIN_SEPARATOR"});
  } catch {
    // Some tokens publish neither. Then the domain cannot be proved and the caller is told so.
  }

  for (const version of ["2", "1"]) {
    const domain = {name, version, chainId, verifyingContract: token};
    if (!published) continue;
    if (separatorFor(domain).toLowerCase() === published.toLowerCase()) {
      return {domain, verified: true, how: `name + version "${version}", checked against DOMAIN_SEPARATOR`};
    }
  }

  return {
    domain: {name, version: "1", chainId, verifyingContract: token},
    verified: false,
    how: "guessed; this token publishes no domain to check against",
  };
}

/** Reads what the visitor needs to see before paying: symbol, decimals, and their balance. */
export async function readAsset(client, token, account) {
  const [symbol, decimals, balance] = await Promise.all([
    client.readContract({address: token, abi: DOMAIN_ABI, functionName: "symbol"}),
    client.readContract({address: token, abi: DOMAIN_ABI, functionName: "decimals"}),
    account
      ? client.readContract({address: token, abi: DOMAIN_ABI, functionName: "balanceOf", args: [account]})
      : Promise.resolve(0n),
  ]);
  return {symbol, decimals, balance};
}

/** A single-use nonce. Random rather than sequential, because EIP-3009 nonces are arbitrary and never reset. */
export function freshNonce() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

/**
 * Signs an x402 `exact` payment and returns the `hookData` a swap carries.
 *
 * @param walletClient A viem wallet client for the payer.
 * @param options.domain The token's EIP-712 domain, from {resolveDomain}.
 * @param options.from The payer.
 * @param options.to The hook, which is the only address that can present this.
 * @param options.value The amount, in the asset's own units.
 * @param options.timeoutSeconds How long the authorization stays valid.
 */
export async function signPayment(walletClient, {domain, from, to, value, timeoutSeconds = 300}) {
  const now = Math.floor(Date.now() / 1000);
  const message = {
    from,
    to,
    value: BigInt(value),
    // Valid from a minute ago, so a wallet or node whose clock runs slightly fast does not reject it outright.
    validAfter: BigInt(now - 60),
    validBefore: BigInt(now + timeoutSeconds),
    nonce: freshNonce(),
  };

  const signature = await walletClient.signTypedData({
    account: from,
    domain,
    types: RECEIVE_TYPES,
    primaryType: "ReceiveWithAuthorization",
    message,
  });

  return {payment: {...message, signature}, hookData: encodeHookData({...message, signature})};
}

/** Packs a signed payment into the `hookData` the hook decodes: the magic prefix, then the Payment struct. */
export function encodeHookData(payment) {
  const encoded = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          {name: "from", type: "address"},
          {name: "value", type: "uint256"},
          {name: "validAfter", type: "uint256"},
          {name: "validBefore", type: "uint256"},
          {name: "nonce", type: "bytes32"},
          {name: "signature", type: "bytes"},
        ],
      },
    ],
    [
      {
        from: payment.from,
        value: BigInt(payment.value),
        validAfter: BigInt(payment.validAfter),
        validBefore: BigInt(payment.validBefore),
        nonce: payment.nonce,
        signature: payment.signature,
      },
    ],
  );
  return concatHex([X402_MAGIC, encoded]);
}

/**
 * The 402 challenge, formatted the way an x402 client would receive it over HTTP.
 *
 * Shown verbatim on the page because it is the point: an agent gets these fields from one `eth_call` against the pool
 * it was already going to trade, with no endpoint to find and no server to be up.
 */
export function asChallenge(requirements, resourceUrl) {
  return {
    x402Version: 1,
    accepts: [
      {
        scheme: requirements.scheme,
        network: `eip155:${requirements.network}`,
        maxAmountRequired: requirements.maxAmountRequired.toString(),
        asset: requirements.asset,
        payTo: requirements.payTo,
        resource: resourceUrl ?? requirements.resource,
        maxTimeoutSeconds: Number(requirements.maxTimeoutSeconds),
      },
    ],
  };
}
