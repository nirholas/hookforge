/**
 * The documents a standalone hook repository ships with.
 *
 * Everything here is derived from the hook's generated manifest, which is itself derived from the Solidity, so a
 * spun-out repository cannot describe its contract as something it is not. The prose that carries the argument (why
 * the mechanism exists, what it is not, where it fails) comes straight from the contract's own NatSpec.
 */

const FLAG_BITS = {
  beforeInitialize: 13,
  afterInitialize: 12,
  beforeAddLiquidity: 11,
  afterAddLiquidity: 10,
  beforeRemoveLiquidity: 9,
  afterRemoveLiquidity: 8,
  beforeSwap: 7,
  afterSwap: 6,
  beforeDonate: 5,
  afterDonate: 4,
  beforeSwapReturnsDelta: 3,
  afterSwapReturnsDelta: 2,
  afterAddLiquidityReturnsDelta: 1,
  afterRemoveLiquidityReturnsDelta: 0,
};

const FLAG_CONSTANTS = {
  beforeInitialize: "BEFORE_INITIALIZE_FLAG",
  afterInitialize: "AFTER_INITIALIZE_FLAG",
  beforeAddLiquidity: "BEFORE_ADD_LIQUIDITY_FLAG",
  afterAddLiquidity: "AFTER_ADD_LIQUIDITY_FLAG",
  beforeRemoveLiquidity: "BEFORE_REMOVE_LIQUIDITY_FLAG",
  afterRemoveLiquidity: "AFTER_REMOVE_LIQUIDITY_FLAG",
  beforeSwap: "BEFORE_SWAP_FLAG",
  afterSwap: "AFTER_SWAP_FLAG",
  beforeDonate: "BEFORE_DONATE_FLAG",
  afterDonate: "AFTER_DONATE_FLAG",
  beforeSwapReturnsDelta: "BEFORE_SWAP_RETURNS_DELTA_FLAG",
  afterSwapReturnsDelta: "AFTER_SWAP_RETURNS_DELTA_FLAG",
  afterAddLiquidityReturnsDelta: "AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG",
  afterRemoveLiquidityReturnsDelta: "AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG",
};

/** The callbacks a hook claims, in the order v4 packs them into an address. */
export function claimedFlags(hook) {
  return Object.keys(FLAG_BITS).filter((name) => hook.permissions?.[name]);
}

/** The Solidity expression for this hook's permission bitmask. */
export function flagExpression(hook) {
  const claimed = claimedFlags(hook);
  if (claimed.length === 0) return "uint160(0)";
  return `uint160(${claimed.map((name) => `Hooks.${FLAG_CONSTANTS[name]}`).join(" | ")})`;
}

/** The numeric mask, for documentation that wants to show the address suffix. */
export function flagMask(hook) {
  return claimedFlags(hook).reduce((mask, name) => mask | (1 << FLAG_BITS[name]), 0);
}

/** Splits a NatSpec `@dev` block, which solc collapses to one line, back into readable paragraphs. */
export function paragraphs(text, sentencesPerParagraph = 3) {
  const sentences = String(text ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .match(/[^.!?]+[.!?]+(\s|$)|[^.!?]+$/g);
  if (!sentences) return "";

  const blocks = [];
  for (let i = 0; i < sentences.length; i += sentencesPerParagraph) {
    blocks.push(sentences.slice(i, i + sentencesPerParagraph).join("").trim());
  }
  return blocks.filter(Boolean).join("\n\n");
}

/** A markdown table of the hook's `configure` parameters, with units inferred from the field names. */
export function parameterTable(hook) {
  const fields = hook.configure?.fields ?? [];
  if (fields.length === 0) return "This hook takes no per-pool configuration.";

  const units = (name) => {
    if (/fee|surcharge/i.test(name)) return "hundredths of a bip (`3000` = 0.30%)";
    if (/bps/i.test(name)) return "basis points (`10000` = 100%)";
    if (/wad/i.test(name)) return "fixed point, `1e18` = 1.0";
    if (/timestamp|maturity|unlock|expiry/i.test(name)) return "unix seconds";
    if (/seconds|halflife|ramp|window|cooldown|horizon|epochlength/i.test(name)) return "seconds";
    if (/wei/i.test(name)) return "wei per gas";
    if (/tick/i.test(name)) return "ticks";
    if (/mask/i.test(name)) return "bitmask";
    return "";
  };

  return [
    "| Parameter | Type | Units |",
    "| --- | --- | --- |",
    ...fields.map((f) => `| \`${f.name}\` | \`${f.type}\` | ${units(f.name)} |`),
  ].join("\n");
}

/** The errors the hook defines itself, excluding the ones every hook inherits. */
export function errorTable(hook) {
  const inherited = new Set(["HookNotImplemented()", "NotPoolManager()", "InvalidPool()"]);
  const own = (hook.errors ?? []).filter((e) => !inherited.has(e.signature));
  if (own.length === 0) return "";

  return [
    "",
    "## What it reverts with",
    "",
    "| Error | Meaning |",
    "| --- | --- |",
    ...own.map((e) => `| \`${e.signature}\` | ${(e.notice ?? "").replace(/\|/g, "\\|")} |`),
  ].join("\n");
}

export function readme(hook, {repo, catalogueUrl, siteUrl}) {
  const claimed = claimedFlags(hook);
  const configureCall = hook.configure
    ? `hook.configure(
    key,
    ${hook.contract}.Config({
${(hook.configure.fields ?? []).map((f) => `        ${f.name}: /* ${f.type} */ 0`).join(",\n") || "        // no parameters"}
    })
);`
    : "// This hook needs no configuration.";

  return `# ${hook.name}

**${hook.summary}**

A production Uniswap v4 hook. ${hook.properties?.dynamicFee ? "It prices every swap by overriding the pool's LP fee, so the value it captures is paid to in-range liquidity and never to the hook." : "It holds no funds and takes no fee for itself."} No owner, no pause switch, no upgrade path.

- **Site:** ${siteUrl}
- **Catalogue:** ${catalogueUrl}
- **Contract:** [\`src/hooks/${hook.contract}.sol\`](src/hooks/${hook.contract}.sol)
- **Licence:** Apache-2.0

## How it works

${paragraphs(hook.description)}

## Prior art

${hook.priorArt || "Not stated."}

## Where it does not help

${hook.limitation || "Not stated."}

## Using it

Uniswap v4 removed \`hookData\` from \`initialize\`, so per-pool parameters arrive out of band. Fix them for a pool key whose pool does not exist yet, then initialize. Nobody can change them afterwards, including you.

\`\`\`solidity
${configureCall}

poolManager.initialize(key, startingSqrtPriceX96);
\`\`\`

${hook.properties?.dynamicFee ? "The pool's `fee` field must be `LPFeeLibrary.DYNAMIC_FEE_FLAG`. The hook rejects a pool initialized without it.\n" : ""}
### Parameters

${parameterTable(hook)}
${errorTable(hook)}

## The callbacks it claims

Uniswap v4 reads a hook's permissions from the low fourteen bits of its own address, which is why deploying one means mining a CREATE2 salt. This hook claims ${claimed.length} of the fourteen:

${claimed.length ? claimed.map((name) => `- \`${name}\``).join("\n") : "- none"}

Mask: \`0x${flagMask(hook).toString(16)}\`, so every deployment of this hook has an address ending in those bits.

## It says what it is, on-chain

Every hook in this family implements \`IHookMetadata\`: four view functions that let an indexer, a wallet, a router or an agent identify a hook from its address alone, with no registry in the loop.

\`\`\`bash
cast call $HOOK "hookName()(string)"    # ${hook.name}
cast call $HOOK "hookVersion()(string)" # ${hook.version}
cast call $HOOK "specURI()(string)"     # the machine-readable manifest
cast call $HOOK "hookTags()(string[])"  # ${hook.tags.join(", ")}
\`\`\`

The manifest this repository ships as [\`hook.json\`](hook.json) is what \`specURI()\` points at.

## Build and test

\`\`\`bash
git clone --recurse-submodules ${repo}
cd ${hook.slug}
forge build
forge test
\`\`\`

Foundry 1.7 or newer, Solidity 0.8.26, EVM version \`cancun\` (Uniswap v4 requires transient storage).

## Deploy

\`\`\`bash
# Dry run: mines the salt and prints the address without sending anything.
forge script script/Deploy.s.sol --rpc-url $RPC_URL

# For real.
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
\`\`\`

Needs \`PRIVATE_KEY\` in the environment and a funded deployer on the target chain. See [\`docs/deploying.md\`](docs/deploying.md).

## Status

**Unaudited.** Built to an audited shape, on OpenZeppelin's audited hook bases, and tested against a real \`PoolManager\`. No third party has reviewed it. Read "where it does not help" above before putting money behind it.

Not affiliated with Uniswap Labs.
`;
}

export function integratingDoc(hook, {siteUrl}) {
  return `# Integrating ${hook.name}

## From Solidity

\`\`\`solidity
import {${hook.contract}} from "${hook.slug}/src/hooks/${hook.contract}.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
${hook.properties?.dynamicFee ? 'import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";\n' : ""}
PoolKey memory key = PoolKey({
    currency0: currencyA,          // must sort below currency1
    currency1: currencyB,
    fee: ${hook.properties?.dynamicFee ? "LPFeeLibrary.DYNAMIC_FEE_FLAG" : "3000"},
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

${hook.configure ? `hook.configure(key, ${hook.contract}.Config({ /* see the README */ }));\n` : ""}poolManager.initialize(key, startingSqrtPriceX96);
\`\`\`

## From TypeScript

\`\`\`ts
import {getHook, hookAddress, poolKeyFor, poolId} from "@hookforge/sdk";

const hook = getHook("${hook.slug}");
const address = hookAddress("${hook.slug}", 8453);              // Base
const key = poolKeyFor({
  hook: address,
  currencyA: USDC,
  currencyB: WETH,
  tickSpacing: 60,${hook.properties?.dynamicFee ? "\n  dynamicFee: true," : ""}
});
console.log(poolId(key));
\`\`\`

## Identifying the hook from an address

Any caller holding only a hook address can find out what it is, without a registry:

\`\`\`solidity
IHookMetadata(hookAddress).hookName();   // "${hook.name}"
IHookMetadata(hookAddress).specURI();    // points at hook.json
\`\`\`

The permission bits are in the address itself, so a caller can also decode what the hook participates in with no call at all:

\`\`\`ts
import {permissionsOf} from "@hookforge/sdk";
permissionsOf(address);
\`\`\`

## Things that will bite you

${hook.properties?.dynamicFee ? "- **The pool must be initialized with the dynamic-fee flag.** The hook reverts at `afterInitialize` otherwise. This is the single most common integration failure.\n" : ""}${hook.configure ? "- **Configure before you initialize.** The parameters are fixed for the pool's lifetime, and a pool the hook was never configured for cannot be created at all.\n- **Anyone can configure a key that has no pool yet.** If someone front-runs your configuration with terms you did not want, pick a different `tickSpacing` and configure that instead. It is a different pool id and it costs them their gas.\n" : ""}${hook.properties?.requiresCustomSwapData ? "- **This hook reads `hookData`.** A router or aggregator that strips it cannot trade the pool.\n" : ""}- **Deterministic addresses are not deployments.** An address published before a deploy is where the hook *will* be. There is no code at it until the deploy runs.

More at ${siteUrl}.
`;
}

export function deployingDoc(hook) {
  return `# Deploying ${hook.name}

## Why it is not an ordinary deploy

Uniswap v4 reads a hook's permissions from the low fourteen bits of its address, and the \`PoolManager\` rejects a pool whose hook address does not match the permissions the hook declares. You cannot deploy a hook to whatever address you happen to get: you mine a CREATE2 salt until the address has the right bits, then deploy with that salt through a deterministic factory.

This hook needs \`0x${flagMask(hook).toString(16)}\` in those bits, from claiming:

${claimedFlags(hook).map((name) => `- \`${name}\``).join("\n") || "- none"}

## Running it

\`\`\`bash
export PRIVATE_KEY=0x...
export RPC_URL=https://mainnet.base.org

# Dry run. Mines the salt, prints the address, sends nothing.
forge script script/Deploy.s.sol --rpc-url $RPC_URL

# For real.
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
\`\`\`

Mining is a view loop that never reaches the chain, but it does consume script gas. On some chains it exhausts the default limit and fails with \`EvmError: OutOfGas\` inside the miner rather than anywhere informative. \`--gas-limit 30000000000\` fixes it and costs nothing.

## The address differs per chain, on purpose

The hook takes its \`PoolManager\` as a constructor argument, so the init code differs per chain and so does the CREATE2 result. What is guaranteed is that the address is a pure function of (source, compiler settings, chain), which is the property that matters: anyone can re-run this script and derive the same address without trusting a published one.

## After deploying

1. Verify the source on the chain's explorer. \`--verify\` above does it if \`ETHERSCAN_API_KEY\` is set.
2. Submit the hook to [Uniswap's hooklist](https://github.com/Uniswap/hooklist), which takes a chain and an address and derives the rest from verified source. Being listed is not an endorsement and does not make a hook allowlisted for routing; the registry says so itself.
3. Publish the manifest at whatever URL the contract returns from \`specURI()\`. That string is immutable, so it has to resolve.

## Supported chains

Every chain with a Uniswap v4 \`PoolManager\`. The address book in [\`src/libraries/Chains.sol\`](../src/libraries/Chains.sol) carries the deployments this repository was built against, including Base, Arbitrum One, Unichain and Robinhood Chain.
`;
}
