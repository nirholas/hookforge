import {encodeAbiParameters, keccak256, type Address, type PublicClient} from "viem";
import registryIndex from "@hookforge/registry/index.json" with {type: "json"};

import {hookMetadataAbi, poolKeyAbi} from "./constants.js";
import type {HookIdentity, HookManifest, HookPermissions, PoolKey} from "./types.js";

export * from "./types.js";
export * from "./constants.js";

/** The fourteen permission bits, least significant first, in the order Uniswap v4 packs them into a hook address. */
const FLAG_BITS = [
  "afterRemoveLiquidityReturnsDelta",
  "afterAddLiquidityReturnsDelta",
  "afterSwapReturnsDelta",
  "beforeSwapReturnsDelta",
  "afterDonate",
  "beforeDonate",
  "afterSwap",
  "beforeSwap",
  "afterRemoveLiquidity",
  "beforeRemoveLiquidity",
  "afterAddLiquidity",
  "beforeAddLiquidity",
  "afterInitialize",
  "beforeInitialize",
] as const;

/**
 * The pool id for a key: `keccak256(abi.encode(key))`, byte-identical to `PoolIdLibrary.toId`.
 *
 * Every read in this SDK is keyed on this, so getting it wrong is the one mistake that silently returns another
 * pool's state rather than failing.
 */
export function poolId(key: PoolKey): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [poolKeyAbi],
      [[key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks] as never],
    ),
  );
}

/**
 * Decodes which callbacks a hook implements from its address.
 *
 * This is not a heuristic. Uniswap v4 itself decides whether to call a hook by masking the low fourteen bits of the
 * hook's address, so these flags are what the protocol will actually do, for any hook, whether or not it publishes an
 * ABI or verifies its source.
 */
export function permissionsFromAddress(address: Address): HookPermissions {
  const low = BigInt(address) & 0x3fffn;
  const permissions = {} as HookPermissions;
  for (const [index, name] of FLAG_BITS.entries()) {
    permissions[name] = ((low >> BigInt(index)) & 1n) === 1n;
  }
  return permissions;
}

/** Whether an address is a hook at all. The zero address is a pool with no hook. */
export function isHook(address: Address): boolean {
  return BigInt(address) !== 0n;
}

/**
 * Asks a hook what it is.
 *
 * Any hook that implements `IHookMetadata` answers with its name, version, spec URI and tags in one multicall. A hook
 * that does not implement it still yields its permissions, because those come from the address rather than from the
 * contract, so this never returns nothing useful.
 */
export async function identifyHook(client: PublicClient, address: Address): Promise<HookIdentity> {
  const permissions = permissionsFromAddress(address);
  const call = (functionName: "hookName" | "hookVersion" | "specURI" | "hookTags") =>
    ({address, abi: hookMetadataAbi, functionName}) as const;

  const results = await client.multicall({
    contracts: [call("hookName"), call("hookVersion"), call("specURI"), call("hookTags")],
    allowFailure: true,
  });

  const [name, version, specURI, tags] = results;
  return {
    address,
    name: name.status === "success" ? (name.result as string) : "",
    version: version.status === "success" ? (version.result as string) : "",
    specURI: specURI.status === "success" ? (specURI.result as string) : "",
    tags: tags.status === "success" ? ([...(tags.result as readonly string[])] as string[]) : [],
    permissions,
  };
}

/** Every hook in the published catalogue. */
export function listHooks(): typeof registryIndex.hooks {
  return registryIndex.hooks;
}

/** One catalogue entry by slug, or `undefined`. */
export function getHookEntry(slug: string) {
  return registryIndex.hooks.find((hook) => hook.slug === slug);
}

/** The deployed address of a hook on a chain, or `undefined` if HookForge has not published one. */
export function hookAddress(slug: string, chainId: number): Address | undefined {
  return getHookEntry(slug)?.deployments.find((d) => d.chainId === chainId)?.address as Address | undefined;
}

/** Catalogue entries filtered by tag, family or chain. All filters are optional and combine with AND. */
export function findHooks(filter: {tag?: string; family?: string; chainId?: number} = {}) {
  return registryIndex.hooks.filter((hook) => {
    if (filter.tag && !hook.tags.includes(filter.tag)) return false;
    if (filter.family && hook.family !== filter.family) return false;
    if (filter.chainId && !hook.deployments.some((d) => d.chainId === filter.chainId)) return false;
    return true;
  });
}

/**
 * Loads a hook's full manifest, including its ABI.
 *
 * Kept as a dynamic import so that a bundle that only needs the index does not pull in fifty ABIs.
 */
export async function loadManifest(slug: string): Promise<HookManifest> {
  const manifest = await import(`@hookforge/registry/hooks/${slug}.json`, {with: {type: "json"}});
  return (manifest.default ?? manifest) as HookManifest;
}

/**
 * Identifies a hook and, when it is one of ours, pairs it with the catalogue entry describing it.
 *
 * This is the call worth making against an unknown v4 pool: it turns a bare address into a name, a set of callbacks,
 * and, if the hook is documented anywhere, a link to what it does.
 */
export async function describePool(
  client: PublicClient,
  key: PoolKey,
): Promise<{poolId: `0x${string}`; hook: HookIdentity | null; catalogue: ReturnType<typeof getHookEntry>}> {
  const id = poolId(key);
  if (!isHook(key.hooks)) return {poolId: id, hook: null, catalogue: undefined};

  const hook = await identifyHook(client, key.hooks);
  const chainId = await client.getChainId();
  const catalogue = registryIndex.hooks.find((entry) =>
    entry.deployments.some((d) => d.chainId === chainId && d.address.toLowerCase() === key.hooks.toLowerCase()),
  );

  return {poolId: id, hook, catalogue};
}
