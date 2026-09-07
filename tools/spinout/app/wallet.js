/**
 * Wallet and chain plumbing, shared by every hook's demo.
 *
 * Deliberately EIP-1193 and nothing else: no wallet-vendor SDK, no connector framework, no project id to register.
 * Every browser wallet worth supporting injects a provider, and the ones that do not are reached through the same
 * interface by an extension the visitor already has. A demo that made somebody sign up for a service before they
 * could press a button would be a worse demo.
 */
import {createPublicClient, createWalletClient, custom, http, formatUnits} from "viem";

/** Chains the demos know how to name. Anything else is shown by its id, which is honest and still usable. */
const CHAINS = {
  1: {name: "Ethereum", explorer: "https://etherscan.io"},
  10: {name: "Optimism", explorer: "https://optimistic.etherscan.io"},
  130: {name: "Unichain", explorer: "https://uniscan.xyz"},
  8453: {name: "Base", explorer: "https://basescan.org"},
  42161: {name: "Arbitrum One", explorer: "https://arbiscan.io"},
  84532: {name: "Base Sepolia", explorer: "https://sepolia.basescan.org"},
  4663: {name: "Robinhood Chain", explorer: ""},
  31337: {name: "Local (anvil)", explorer: ""},
};

export function chainName(id) {
  return CHAINS[id]?.name ?? `chain ${id}`;
}

export function explorerFor(id, kind, value) {
  const base = CHAINS[id]?.explorer;
  if (!base) return null;
  return `${base}/${kind}/${value}`;
}

/** The injected provider, or null. Never throws: a page with no wallet must still render. */
export function provider() {
  return typeof window !== "undefined" && window.ethereum ? window.ethereum : null;
}

/** A chain definition viem accepts, built from the id alone so no chain needs to be pre-registered. */
function chainFor(id, rpcUrl) {
  return {
    id,
    name: chainName(id),
    nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
    rpcUrls: {default: {http: rpcUrl ? [rpcUrl] : []}},
  };
}

export function publicClientFor(chainId, rpcUrl) {
  const injected = provider();
  // Prefer the wallet's own transport: it is already connected to the chain the user is on, and an RPC we picked
  // might not be.
  const transport = injected && !rpcUrl ? custom(injected) : http(rpcUrl);
  return createPublicClient({chain: chainFor(chainId, rpcUrl), transport});
}

export function walletClientFor(chainId, account) {
  return createWalletClient({chain: chainFor(chainId), transport: custom(provider()), account});
}

/**
 * Connects, returning the account and chain, or a reason it could not.
 * @returns {Promise<{account?: string, chainId?: number, error?: string}>}
 */
export async function connect() {
  const injected = provider();
  if (!injected) {
    return {error: "No wallet found. Install a browser wallet, or run the local demo, which needs no wallet at all."};
  }
  try {
    const accounts = await injected.request({method: "eth_requestAccounts"});
    const chainId = Number(await injected.request({method: "eth_chainId"}));
    return {account: accounts[0], chainId};
  } catch (error) {
    return {error: error?.shortMessage ?? error?.message ?? "The wallet rejected the request."};
  }
}

/** Watches for the visitor switching account or chain, which they will, and usually mid-flow. */
export function watch(onChange) {
  const injected = provider();
  if (!injected?.on) return () => {};
  const onAccounts = (accounts) => onChange({account: accounts[0] ?? null});
  const onChain = (hex) => onChange({chainId: Number(hex)});
  injected.on("accountsChanged", onAccounts);
  injected.on("chainChanged", onChain);
  return () => {
    injected.removeListener?.("accountsChanged", onAccounts);
    injected.removeListener?.("chainChanged", onChain);
  };
}

export function shortAddress(address) {
  return address ? `${address.slice(0, 6)}…${address.slice(-4)}` : "";
}

export function formatAmount(value, decimals, places = 4) {
  const text = formatUnits(value ?? 0n, decimals);
  const [whole, fraction = ""] = text.split(".");
  return fraction ? `${whole}.${fraction.slice(0, places).padEnd(places, "0")}` : whole;
}

/**
 * Turns a contract revert into something a person can act on.
 *
 * viem surfaces the custom error name and arguments, which is most of the way there; the part that matters is not
 * showing a stack trace to somebody who just wanted to press a button.
 */
export function readableError(error) {
  const name = error?.cause?.data?.errorName ?? error?.data?.errorName;
  const args = error?.cause?.data?.args ?? error?.data?.args;
  if (name) return args?.length ? `${name}(${args.join(", ")})` : name;
  if (error?.shortMessage) return error.shortMessage;
  return error?.message?.split("\n")[0] ?? "The transaction failed.";
}
