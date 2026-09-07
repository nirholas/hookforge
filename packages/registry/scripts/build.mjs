#!/usr/bin/env node
/**
 * Generates the HookForge registry from the Solidity source of truth.
 *
 * Everything published about a hook comes from one place: the contract. The prose is its NatSpec, the parameters are
 * its `configure` ABI, the permission flags are the low fourteen bits of its deterministic address, and the tags are
 * the strings its own `hookTags()` returns. Nothing here is hand-maintained, so a hook cannot be documented as
 * something it is not.
 *
 * Reads:   contracts/out/<Contract>.sol/<Contract>.json   (ABI, devdoc, userdoc)
 *          contracts/src/hooks/<Contract>.sol             (custom NatSpec tags, tag list)
 *          contracts/src/libraries/Chains.sol             (chain id, PoolManager, slug)
 *          contracts/deployments/<chainId>.json           (deterministic addresses)
 * Writes:  packages/registry/hooks/<slug>.json
 *          packages/registry/index.json
 *          packages/registry/chains.json
 */
import {readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..", "..");
const CONTRACTS = join(ROOT, "contracts");
const OUT = join(HERE, "..");
const SPINOUTS = join(ROOT, "tools", "spinout", "sites.json");

/** Where each hook's own repository and site live, once it has been spun out into one. */
const spinouts = existsSync(SPINOUTS) ? JSON.parse(readFileSync(SPINOUTS, "utf8")) : {};

/** The fourteen Uniswap v4 hook permission bits, least significant first. */
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
];

/** Reads the contract-level `@custom:` NatSpec tags, which solc does not surface in devdoc. */
function customTags(source) {
  const docBlock = source.slice(0, source.search(/\ncontract\s/));
  const start = docBlock.lastIndexOf("/**");
  if (start === -1) return {};

  const body = docBlock.slice(start);
  const tags = {};
  const re = /@custom:([a-z][a-z-]*)\s+([\s\S]*?)(?=\n\s*\*\s*@custom:|\n\s*\*\/)/g;
  for (const match of body.matchAll(re)) {
    tags[match[1]] = match[2]
      .split("\n")
      .map((line) => line.replace(/^\s*\*\s?/, "").trim())
      .join(" ")
      .trim();
  }
  return tags;
}

/** Reads the tag list the hook returns from `hookTags()`, so the registry and the chain agree. */
function hookTags(source) {
  return [...source.matchAll(/tags\[\d+\]\s*=\s*"([^"]+)"/g)].map((m) => m[1]);
}

/** Reads the human name the hook returns from `hookName()`. */
function hookName(source) {
  const match = source.match(/function hookName\(\)[\s\S]*?return "([^"]+)"/);
  return match?.[1] ?? null;
}

/** Decodes the fourteen permission flags from a hook address, which is where v4 actually reads them from. */
function permissionsFromAddress(address) {
  const low = BigInt(address) & 0x3fffn;
  const permissions = {};
  for (const [index, name] of FLAG_BITS.entries()) permissions[name] = ((low >> BigInt(index)) & 1n) === 1n;
  return permissions;
}

/** Parses the chain table out of Chains.sol so the registry cannot disagree with the contracts. */
function readChains() {
  const source = readFileSync(join(CONTRACTS, "src", "libraries", "Chains.sol"), "utf8");
  const ids = Object.fromEntries(
    [...source.matchAll(/uint256 internal constant ([A-Z]+) = (\d+);/g)].map((m) => [m[1], Number(m[2])]),
  );
  const managers = Object.fromEntries(
    [...source.matchAll(/chainId == ([A-Z]+)\) return IPoolManager\((0x[0-9a-fA-F]{40})\)/g)].map((m) => [m[1], m[2]]),
  );
  const slugs = Object.fromEntries(
    [...source.matchAll(/chainId == ([A-Z]+)\) return "([a-z]+)"/g)].map((m) => [m[1], m[2]]),
  );

  return Object.keys(ids)
    .filter((key) => managers[key] && slugs[key])
    .map((key) => ({slug: slugs[key], chainId: ids[key], poolManager: managers[key]}))
    .sort((a, b) => a.chainId - b.chainId);
}

/** Reads every `deployments/<chainId>.json` the deploy script has written. */
function readDeployments(chains) {
  const dir = join(CONTRACTS, "deployments");
  if (!existsSync(dir)) return {};

  const byHook = {};
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".json"))) {
    const chainId = Number(file.replace(".json", ""));
    const chain = chains.find((c) => c.chainId === chainId);
    if (!chain) continue;

    for (const [name, address] of Object.entries(JSON.parse(readFileSync(join(dir, file), "utf8")))) {
      (byHook[name] ??= []).push({chain: chain.slug, chainId, address});
    }
  }
  for (const list of Object.values(byHook)) list.sort((a, b) => a.chainId - b.chainId);
  return byHook;
}

/**
 * Reads the permission flags a hook declares in `getHookPermissions()`.
 *
 * A deployed hook's flags are the low fourteen bits of its address, which is the only thing v4 itself consults. Before
 * a hook is deployed there is no address to read, so the declaration in the source is the next best source of truth,
 * and the deploy script mines an address to match it. Hooks that inherit their permissions from a base (a fee hook
 * declares none of its own) fall back to that base's declaration.
 */
function permissionsFromSource(source) {
  const declared = source.match(/function getHookPermissions\(\)[\s\S]*?Hooks\.Permissions\(\{([\s\S]*?)\}\)/);
  const body = declared?.[1] ?? (source.includes("ForgeFeeHook") ? "afterInitialize: true, beforeSwap: true" : null);
  if (body === null) return null;

  const set = Object.fromEntries(
    [...body.matchAll(/(\w+)\s*:\s*(true|false)/g)].map((m) => [m[1], m[2] === "true"]),
  );
  // The v4 struct spells the delta flags "ReturnDelta"; the address bits are named "ReturnsDelta". Normalise.
  const alias = (name) => set[name] ?? set[name.replace("Returns", "Return")] ?? false;
  return Object.fromEntries(FLAG_BITS.map((name) => [name, alias(name)]));
}

/** Describes the `configure` entry point so a client can build the call without the ABI in hand. */
function describeConfigure(abi) {
  const fn = abi.find((entry) => entry.type === "function" && entry.name === "configure");
  if (!fn) return null;

  /** Canonical ABI signature: tuples expand to their component types, which is what a selector is computed over. */
  const canonical = (input) =>
    input.type.startsWith("tuple")
      ? `(${input.components.map(canonical).join(",")})${input.type.slice("tuple".length)}`
      : input.type;

  const config = fn.inputs.at(-1);
  return {
    signature: `configure(${fn.inputs.map(canonical).join(",")})`,
    fields: (config?.components ?? []).map((c) => ({name: c.name, type: c.type})),
  };
}

function buildHook(contractName, chains, deployments) {
  const artifactPath = join(CONTRACTS, "out", `${contractName}.sol`, `${contractName}.json`);
  const sourcePath = join(CONTRACTS, "src", "hooks", `${contractName}.sol`);
  if (!existsSync(artifactPath) || !existsSync(sourcePath)) return null;

  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const source = readFileSync(sourcePath, "utf8");
  const tags = customTags(source);
  const name = hookName(source) ?? contractName;

  const addresses = deployments[name] ?? [];
  // Prefer the deployed address, which is what v4 reads; fall back to the source declaration the deploy
  // script mines that address to satisfy, so the registry is complete before a hook ships.
  const permissions = addresses.length ? permissionsFromAddress(addresses[0].address) : permissionsFromSource(source);
  const permissionsSource = addresses.length ? "address" : "declaration";
  const abi = artifact.abi ?? [];

  return {
    $schema: "https://hookforge.pages.dev/schema/hook-manifest.json",
    slug: tags.slug ?? contractName.toLowerCase(),
    name,
    contract: contractName,
    version: "1.0.0",
    family: tags.family ?? "Uncategorised",
    summary: artifact.userdoc?.notice ?? "",
    description: artifact.devdoc?.details ?? "",
    priorArt: tags["prior-art"] ?? "",
    limitation: tags.limitation ?? "",
    tags: hookTags(source),
    recommendedChains: (tags.chains ?? "").split(",").filter(Boolean),
    source: `contracts/src/hooks/${contractName}.sol`,
    docs: `https://hookforge.pages.dev/hooks/${tags.slug ?? contractName.toLowerCase()}`,
    // A spun-out hook has a repository and a site of its own. Absent until it does.
    repo: spinouts[tags.slug] ? `https://github.com/nirholas/${tags.slug}` : null,
    site: spinouts[tags.slug] ?? null,
    permissions,
    permissionsSource,
    properties: {
      dynamicFee: source.includes("ForgeFeeHook"),
      upgradeable: false,
      // True only when the hook actually reads `hookData`, which is what forces a caller off a standard router.
      requiresCustomSwapData: source.includes("abi.decode(hookData"),
      // True when the hook never returns a delta of its own, so the pool's own curve settles the swap.
      vanillaSwap: !/BeforeSwapDelta(?!Library)\s+\w+\s*=|toBeforeSwapDelta\(/.test(source),
      swapAccess: source.includes("revert PoolHalted") ? "temporal" : "none",
    },
    configure: describeConfigure(abi),
    errors: Object.entries(artifact.devdoc?.errors ?? {}).map(([signature, entries]) => ({
      signature,
      notice: entries?.[0]?.details ?? "",
    })),
    deployments: addresses.map((d) => ({...d, status: "deterministic"})),
    abi,
  };
}

function main() {
  const chains = readChains();
  const deployments = readDeployments(chains);

  const hooksDir = join(CONTRACTS, "src", "hooks");
  const contracts = readdirSync(hooksDir)
    .filter((f) => f.endsWith(".sol"))
    .map((f) => f.replace(".sol", ""))
    .sort();

  mkdirSync(join(OUT, "hooks"), {recursive: true});

  const index = [];
  for (const contractName of contracts) {
    const hook = buildHook(contractName, chains, deployments);
    if (!hook) {
      console.warn(`skipping ${contractName}: no build artifact, run \`forge build\` first`);
      continue;
    }

    writeFileSync(join(OUT, "hooks", `${hook.slug}.json`), `${JSON.stringify(hook, null, 2)}\n`);
    index.push({
      slug: hook.slug,
      name: hook.name,
      family: hook.family,
      summary: hook.summary,
      tags: hook.tags,
      docs: hook.docs,
      manifest: `https://hookforge.pages.dev/schema/hooks/${hook.slug}.json`,
      repo: hook.repo,
      site: hook.site,
      // `status` rides along: a deterministic address is where the hook *will* be, and a consumer that cannot
      // tell that from a live deployment would misreport an undeployed hook as live.
      deployments: hook.deployments.map((d) => ({chain: d.chain, chainId: d.chainId, address: d.address, status: d.status})),
    });
    console.log(`generated ${hook.slug}.json`);
  }

  writeFileSync(
    join(OUT, "index.json"),
    `${JSON.stringify(
      {
        $schema: "https://hookforge.pages.dev/schema/registry.json",
        name: "HookForge",
        description: "Production Uniswap v4 hooks with on-chain self-description.",
        homepage: "https://hookforge.pages.dev",
        generated: new Date().toISOString().slice(0, 10),
        count: index.length,
        hooks: index,
      },
      null,
      2,
    )}\n`,
  );
  writeFileSync(join(OUT, "chains.json"), `${JSON.stringify({chains}, null, 2)}\n`);
  console.log(`\n${index.length} hooks, ${chains.length} chains`);
}

main();
