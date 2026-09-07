import type {PoolKey} from "./types.js";

/** Uniswap's dynamic-fee sentinel. A pool must be initialized with this for a fee-overriding hook to work. */
export const DYNAMIC_FEE_FLAG = 0x800000;

/** The flag a hook ORs into a returned fee to override the pool's stored LP fee for one swap. */
export const OVERRIDE_FEE_FLAG = 0x400000;

/** 100% in hundredths of a bip, the largest LP fee Uniswap v4 accepts. */
export const MAX_LP_FEE = 1_000_000;

/** The deterministic CREATE2 proxy every HookForge address is mined against. */
export const CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C" as const;

/** `IHookMetadata`, the four view functions every HookForge hook answers. */
export const hookMetadataAbi = [
  {type: "function", name: "hookName", inputs: [], outputs: [{type: "string"}], stateMutability: "view"},
  {type: "function", name: "hookVersion", inputs: [], outputs: [{type: "string"}], stateMutability: "view"},
  {type: "function", name: "specURI", inputs: [], outputs: [{type: "string"}], stateMutability: "view"},
  {type: "function", name: "hookTags", inputs: [], outputs: [{type: "string[]"}], stateMutability: "view"},
] as const;

/** The ABI type of a `PoolKey`, needed wherever a pool is addressed. */
export const poolKeyAbi = {
  type: "tuple",
  components: [
    {name: "currency0", type: "address"},
    {name: "currency1", type: "address"},
    {name: "fee", type: "uint24"},
    {name: "tickSpacing", type: "int24"},
    {name: "hooks", type: "address"},
  ],
} as const;

/** Formats an LP fee in pips as a percentage string, e.g. `3000` becomes `"0.30%"`. */
export function formatFee(pips: number): string {
  return `${(pips / 10_000).toFixed(2)}%`;
}

/** Sorts two currencies into the order a `PoolKey` requires. */
export function sortCurrencies(a: `0x${string}`, b: `0x${string}`): [`0x${string}`, `0x${string}`] {
  return BigInt(a) < BigInt(b) ? [a, b] : [b, a];
}

/** Builds a `PoolKey` with the currencies sorted and the dynamic-fee flag set, which fee hooks require. */
export function dynamicFeePoolKey(
  currencyA: `0x${string}`,
  currencyB: `0x${string}`,
  tickSpacing: number,
  hooks: `0x${string}`,
): PoolKey {
  const [currency0, currency1] = sortCurrencies(currencyA, currencyB);
  return {currency0, currency1, fee: DYNAMIC_FEE_FLAG, tickSpacing, hooks};
}
