# @hookforge/registry

Machine-readable manifests for every HookForge Uniswap v4 hook.

Everything in this package is generated from the contracts. The prose comes from each hook's NatSpec, the parameters
from its `configure` ABI, the permission flags from the low fourteen bits of its deterministic address, and the tag
list from the strings the hook's own `hookTags()` returns on-chain. Nothing is hand-maintained, so a hook cannot be
described here as something it is not.

## Install

```bash
npm install @hookforge/registry
```

## Use

```js
import registry from "@hookforge/registry/index.json" with {type: "json"};
import breaker from "@hookforge/registry/hooks/circuit-breaker.json" with {type: "json"};

console.log(registry.count, "hooks");
console.log(breaker.permissions.afterSwap); // true
console.log(breaker.deployments); // [{ chain: "base", chainId: 8453, address: "0x..." }, ...]
```

## What a manifest contains

| Field | Meaning |
| --- | --- |
| `slug`, `name`, `contract` | Identity. `name` is what the deployed contract returns from `hookName()`. |
| `family`, `tags` | Classification, drawn from the HookForge taxonomy. |
| `summary`, `description` | The hook's own `@notice` and `@dev` documentation. |
| `priorArt` | What already existed and what this hook does differently. Every hook has one. |
| `limitation` | Where the hook does not help. Every hook has one of these too. |
| `permissions` | The fourteen v4 callback flags, decoded from the hook address. |
| `properties` | `dynamicFee`, `upgradeable`, `requiresCustomSwapData`, `vanillaSwap`, `swapAccess`, matching the fields Uniswap's hooklist records. |
| `configure` | The canonical signature and field list for the hook's one-time per-pool setup call. |
| `errors` | Every custom error the hook can revert with, and what each means. |
| `deployments` | Chain, chain id and address, per chain. |
| `abi` | The full ABI, so a client needs nothing else. |

## Regenerate

```bash
forge build --root contracts
node packages/registry/scripts/build.mjs
```

`chains.json` is parsed out of `contracts/src/libraries/Chains.sol`, so the registry and the contracts cannot disagree
about which `PoolManager` lives on which chain.
