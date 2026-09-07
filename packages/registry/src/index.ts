import index from "../index.json" with {type: "json"};
import chains from "../chains.json" with {type: "json"};

export type RegistryIndex = typeof index;
export type RegistryEntry = RegistryIndex["hooks"][number];
export type ChainRecord = (typeof chains)["chains"][number];

/** The published catalogue: every hook, its classification, and where it is deployed. */
export const registry: RegistryIndex = index;

/** Every chain HookForge knows a Uniswap v4 `PoolManager` on, parsed from the contracts. */
export const chainList: ChainRecord[] = chains.chains;

/** One catalogue entry by slug. */
export function getHook(slug: string): RegistryEntry | undefined {
  return index.hooks.find((hook) => hook.slug === slug);
}

/** The `PoolManager` for a chain id, or `undefined` if v4 is not deployed there. */
export function poolManager(chainId: number): string | undefined {
  return chainList.find((chain) => chain.chainId === chainId)?.poolManager;
}
