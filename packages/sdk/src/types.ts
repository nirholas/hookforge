/** A Uniswap v4 pool key. Field order matters: it is what the pool id is keccak'd from. */
export interface PoolKey {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
}

/** The fourteen v4 hook permission flags. */
export interface HookPermissions {
  beforeInitialize: boolean;
  afterInitialize: boolean;
  beforeAddLiquidity: boolean;
  afterAddLiquidity: boolean;
  beforeRemoveLiquidity: boolean;
  afterRemoveLiquidity: boolean;
  beforeSwap: boolean;
  afterSwap: boolean;
  beforeDonate: boolean;
  afterDonate: boolean;
  beforeSwapReturnsDelta: boolean;
  afterSwapReturnsDelta: boolean;
  afterAddLiquidityReturnsDelta: boolean;
  afterRemoveLiquidityReturnsDelta: boolean;
}

/** What a hook says about itself when asked, per `IHookMetadata`. */
export interface HookIdentity {
  address: `0x${string}`;
  name: string;
  version: string;
  specURI: string;
  tags: string[];
  permissions: HookPermissions;
}

/** One deployment of a hook. */
export interface HookDeployment {
  chain: string;
  chainId: number;
  address: `0x${string}`;
}

/** A generated registry manifest. */
export interface HookManifest {
  slug: string;
  name: string;
  contract: string;
  version: string;
  family: string;
  summary: string;
  description: string;
  priorArt: string;
  limitation: string;
  tags: string[];
  recommendedChains: string[];
  source: string;
  docs: string;
  permissions: HookPermissions | null;
  properties: {
    dynamicFee: boolean;
    upgradeable: boolean;
    requiresCustomSwapData: boolean;
    vanillaSwap: boolean;
    swapAccess: string;
  };
  configure: {signature: string; fields: {name: string; type: string}[]} | null;
  errors: {signature: string; notice: string}[];
  deployments: HookDeployment[];
  abi: readonly unknown[];
}
