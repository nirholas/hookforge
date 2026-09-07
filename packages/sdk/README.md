# @hookforge/sdk

TypeScript client for HookForge Uniswap v4 hooks. Built on [viem](https://viem.sh).

```bash
npm install @hookforge/sdk viem
```

## Ask an unknown pool what it is

The most useful thing here works on *any* v4 pool, not just ours. A hook's address encodes which callbacks Uniswap
will invoke on it, so the permissions can be read without the contract's cooperation; and any hook implementing
`IHookMetadata` will also tell you its name, version and tags.

```ts
import {createPublicClient, http} from "viem";
import {base} from "viem/chains";
import {describePool} from "@hookforge/sdk";

const client = createPublicClient({chain: base, transport: http()});

const {poolId, hook, catalogue} = await describePool(client, {
  currency0: "0x4200000000000000000000000000000000000006",
  currency1: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  fee: 0x800000,
  tickSpacing: 60,
  hooks: "0x4893e7438ee8d2Ee400b7c4d88493f0F51e650C0",
});

hook.name;                  // "CircuitBreaker"
hook.permissions.afterSwap; // true, read from the address itself
catalogue?.docs;            // https://hookforge.dev/hooks/circuit-breaker
```

## Browse the catalogue

```ts
import {listHooks, findHooks, hookAddress, loadManifest} from "@hookforge/sdk";

findHooks({tag: "mev", chainId: 8453});      // every MEV hook deployed on Base
hookAddress("depeg-shield", 42161);          // its address on Arbitrum One
const manifest = await loadManifest("depeg-shield");
manifest.configure.fields;                   // [{name: "pegTick", type: "int24"}, ...]
manifest.limitation;                         // where this hook does not help
```

## Build a pool key

A fee-overriding hook only works on a pool initialized with Uniswap's dynamic-fee sentinel, and a `PoolKey`'s
currencies must be sorted. `dynamicFeePoolKey` does both, and `poolId` derives the id exactly as `PoolIdLibrary.toId`
does on-chain (there is a test asserting the two agree byte for byte).

```ts
import {dynamicFeePoolKey, poolId} from "@hookforge/sdk";

const key = dynamicFeePoolKey(usdc, weth, 60, hookAddress("arb-tax-decay", 8453)!);
const id = poolId(key);
```

## API

| Export | Purpose |
| --- | --- |
| `describePool(client, key)` | Pool id, hook identity and catalogue entry for any v4 pool. |
| `identifyHook(client, address)` | Name, version, spec URI, tags and permissions for any hook address. |
| `permissionsFromAddress(address)` | The fourteen callback flags, decoded from the address. Works offline. |
| `poolId(key)` | `keccak256(abi.encode(key))`, matching `PoolIdLibrary.toId`. |
| `listHooks()`, `findHooks(filter)`, `getHookEntry(slug)` | The published catalogue. |
| `hookAddress(slug, chainId)` | A deployment address. |
| `loadManifest(slug)` | The full manifest, including ABI, parameters, prior art and limitations. |
| `dynamicFeePoolKey(a, b, tickSpacing, hooks)` | A sorted key with the dynamic-fee flag set. |
| `formatFee(pips)` | `3000` becomes `"0.30%"`. |
