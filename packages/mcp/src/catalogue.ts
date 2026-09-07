import {createRequire} from "node:module";

const require = createRequire(import.meta.url);

/** The generated catalogue index, loaded through `require` so the JSON ships with the package on every Node version. */
export const registry = require("@hookforge/registry/index.json") as {
  count: number;
  homepage: string;
  hooks: CatalogueEntry[];
};

export const chains = (require("@hookforge/registry/chains.json") as {chains: ChainRecord[]}).chains;

export interface ChainRecord {
  slug: string;
  chainId: number;
  poolManager: string;
}

export interface CatalogueEntry {
  slug: string;
  name: string;
  family: string;
  summary: string;
  tags: string[];
  docs: string;
  manifest: string;
  deployments: {chain: string; chainId: number; address: string}[];
}

export interface Manifest extends CatalogueEntry {
  contract: string;
  version: string;
  description: string;
  priorArt: string;
  limitation: string;
  recommendedChains: string[];
  source: string;
  permissions: Record<string, boolean> | null;
  properties: Record<string, unknown>;
  configure: {signature: string; fields: {name: string; type: string}[]} | null;
  errors: {signature: string; notice: string}[];
  abi: unknown[];
}

/** Loads one hook's full manifest, or `null` when the slug is unknown. */
export function loadManifest(slug: string): Manifest | null {
  try {
    return require(`@hookforge/registry/hooks/${slug}.json`) as Manifest;
  } catch {
    return null;
  }
}

/** The fourteen v4 permission bits, least significant first, in the order the protocol packs them into an address. */
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
 * Decodes which callbacks Uniswap v4 will invoke on a hook, from the hook's address alone.
 *
 * No network access and no source verification needed: the protocol masks the low fourteen bits of the address to
 * decide what to call, so this is authoritative for any hook anywhere.
 */
export function permissionsFromAddress(address: string): Record<string, boolean> {
  const low = BigInt(address) & 0x3fffn;
  const permissions: Record<string, boolean> = {};
  for (const [index, name] of FLAG_BITS.entries()) permissions[name] = ((low >> BigInt(index)) & 1n) === 1n;
  return permissions;
}

/**
 * Ranks catalogue entries against a free-text problem statement.
 *
 * Deliberately a transparent keyword score rather than an embedding: an agent asking "how do I stop my pool being
 * drained on a depeg" should be able to see exactly why it got the answer it got, and the catalogue is small enough
 * that recall is not the constraint.
 */
export function searchHooks(query: string, limit = 5): {entry: CatalogueEntry; score: number; matched: string[]}[] {
  const terms = query
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((term) => term.length > 2);
  if (terms.length === 0) return [];

  const scored = registry.hooks.map((entry) => {
    const haystack = {
      name: entry.name.toLowerCase(),
      tags: entry.tags.join(" ").toLowerCase(),
      family: entry.family.toLowerCase(),
      summary: entry.summary.toLowerCase(),
    };

    let score = 0;
    const matched: string[] = [];
    for (const term of terms) {
      if (haystack.tags.includes(term)) (score += 5), matched.push(`tag:${term}`);
      if (haystack.name.includes(term)) (score += 4), matched.push(`name:${term}`);
      if (haystack.family.includes(term)) (score += 2), matched.push(`family:${term}`);
      if (haystack.summary.includes(term)) (score += 1), matched.push(`summary:${term}`);
    }
    return {entry, score, matched};
  });

  return scored
    .filter((result) => result.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
