#!/usr/bin/env node
/**
 * Spins one hook out into a complete, standalone repository.
 *
 * The catalogue is the place the hooks are written and tested together; a spun-out repository is the place one
 * mechanism is published, documented and deployed on its own. Everything in it is generated from the catalogue, so the
 * two cannot drift: regenerating overwrites the generated files and leaves the git history alone.
 *
 * What lands in each repository:
 *
 *   src/            the hook and exactly the shared files it imports, at their original paths so no import is rewritten
 *   test/           its suite, running against a real PoolManager
 *   script/         a deploy script that mines the CREATE2 salt this hook's permission bits require
 *   docs/           integrating and deploying, written for someone who has never seen the catalogue
 *   web/            its own site, built by tools/spinout/site.mjs
 *   hook.json       the manifest specURI() points at
 *   README.md       the argument for the mechanism, its prior art, and what it does not do
 *
 * Usage:
 *   node tools/spinout/generate.mjs <slug> [--out <dir>]
 *   node tools/spinout/generate.mjs --all [--out <dir>]
 */
import {cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

import {closure} from "./resolve.mjs";
import {claimedFlags, deployingDoc, flagExpression, integratingDoc, readme} from "./templates.mjs";
import {emitSite, hasLocalDemo} from "./site.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");
const CONTRACTS = join(ROOT, "contracts");
const REGISTRY = join(ROOT, "packages", "registry");

const CATALOGUE_URL = "https://hookforge.pages.dev";

/** Where each spun-out site actually answers, recorded after the Pages projects were created. */
const SITES = existsSync(join(HERE, "sites.json")) ? JSON.parse(readFileSync(join(HERE, "sites.json"), "utf8")) : {};
const OWNER = "nirholas";

/** Every generated manifest, keyed by slug. */
function manifests() {
  const dir = join(REGISTRY, "hooks");
  return Object.fromEntries(
    readdirSync(dir)
      .filter((file) => file.endsWith(".json"))
      .map((file) => {
        const hook = JSON.parse(readFileSync(join(dir, file), "utf8"));
        return [hook.slug, hook];
      }),
  );
}

function write(root, path, contents) {
  const full = join(root, path);
  mkdirSync(dirname(full), {recursive: true});
  writeFileSync(full, contents);
}

/** The deploy script for one hook: mine the salt its flags require, deploy, record the address. */
function deployScript(hook) {
  return `// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {Chains} from "src/libraries/Chains.sol";
import {IHookMetadata} from "src/interfaces/IHookMetadata.sol";
import {${hook.contract}} from "src/hooks/${hook.contract}.sol";

/**
 * @title Deploy${hook.name}
 * @notice Deploys ${hook.name} deterministically to any chain with a Uniswap v4 \`PoolManager\`.
 *
 * @dev A v4 hook only works at an address whose low fourteen bits spell out the callbacks it implements, so the
 * deployment starts by mining a CREATE2 salt. Mining against \`Chains.CREATE2_DEPLOYER\` makes the result
 * reproducible: anyone can re-run this script and derive the same address without trusting a published one.
 *
 * The address is not the same on every chain, because the hook takes its \`PoolManager\` as a constructor argument
 * and that changes the init code. What is guaranteed is that the address is a pure function of (source, compiler
 * settings, chain).
 *
 * Usage:
 *
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL                       # dry run, sends nothing
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify  # for real
 *
 * Salt mining is a view loop that never reaches the chain, but it does consume script gas; some chains need
 * \`--gas-limit 30000000000\` or it fails with \`EvmError: OutOfGas\` inside the miner.
 *
 * Requires \`PRIVATE_KEY\` in the environment (or \`--account\` / \`--ledger\`). Re-running is safe: a hook already
 * deployed at its mined address is reported and skipped rather than redeployed.
 */
contract Deploy${hook.name} is Script {
    uint160 internal constant FLAGS = ${flagExpression(hook)};

    function run() external {
        IPoolManager manager = Chains.poolManager(block.chainid);
        require(address(manager) != address(0), "no Uniswap v4 PoolManager known for this chain");

        bytes memory creationCode = type(${hook.contract}).creationCode;
        bytes memory constructorArgs = abi.encode(manager);

        (address predicted, bytes32 salt) =
            HookMiner.find(Chains.CREATE2_DEPLOYER, FLAGS, creationCode, constructorArgs);

        console2.log("chain          ", block.chainid);
        console2.log("PoolManager    ", address(manager));
        console2.log("${hook.name} ", predicted);

        if (predicted.code.length > 0) {
            console2.log("already deployed; nothing to do");
            return;
        }

        vm.startBroadcast();
        ${hook.contract} hook = new ${hook.contract}{salt: salt}(manager);
        vm.stopBroadcast();

        require(address(hook) == predicted, "mined address did not match the deployment");
        // A hook that cannot say what it is defeats the point of the catalogue, so prove it answers before finishing.
        require(
            keccak256(bytes(IHookMetadata(address(hook)).hookName())) == keccak256(bytes("${hook.name}")),
            "deployed hook does not identify itself"
        );

        console2.log("deployed and verified self-description");
    }
}
`;
}

function packageJson(hook) {
  return `${JSON.stringify(
    {
      name: hook.slug,
      version: hook.version,
      private: true,
      description: hook.summary,
      license: "Apache-2.0",
      repository: {type: "git", url: `https://github.com/${OWNER}/${hook.slug}.git`},
      homepage: SITES[hook.slug] ?? `https://${hook.slug}.pages.dev`,
      keywords: ["uniswap", "uniswap-v4", "uniswap-hooks", "defi", "amm", "solidity", ...hook.tags],
      scripts: {
        build: "node web/build.mjs",
        "contracts:build": "forge build",
        "contracts:test": "forge test",
      },
    },
    null,
    2,
  )}\n`;
}

export function generate(slug, outRoot) {
  const all = manifests();
  const hook = all[slug];
  if (!hook) throw new Error(`no manifest for "${slug}". Run npm run build:registry first.`);

  const repo = join(outRoot, slug);
  const testFile = `test/${hook.contract}.t.sol`;
  const entries = [`src/hooks/${hook.contract}.sol`, testFile, "test/utils/ForgeTest.sol"];
  if (!existsSync(join(CONTRACTS, testFile))) throw new Error(`no test suite at ${testFile}`);

  // The hook's own closure, plus the two files every deploy script needs.
  const files = new Set([...closure(CONTRACTS, entries), "src/libraries/Chains.sol", "src/interfaces/IHookMetadata.sol"]);

  // A hook that ships a local-deploy script also needs the demo contracts that script stands up. They are not in the
  // hook's import graph, so they have to be named.
  if (hasLocalDemo(slug)) {
    for (const file of closure(CONTRACTS, ["src/demo/DemoToken.sol", "src/demo/DemoRouter.sol"])) files.add(file);
  }

  mkdirSync(repo, {recursive: true});
  for (const file of files) {
    mkdirSync(dirname(join(repo, file)), {recursive: true});
    cpSync(join(CONTRACTS, file), join(repo, file));
  }

  cpSync(join(CONTRACTS, "foundry.toml"), join(repo, "foundry.toml"));
  cpSync(join(CONTRACTS, "remappings.txt"), join(repo, "remappings.txt"));
  cpSync(join(ROOT, "LICENSE"), join(repo, "LICENSE"));
  // Apache-2.0 asks that a NOTICE travel with the work, and it is where the MIT dependencies are credited.
  cpSync(join(ROOT, "NOTICE"), join(repo, "NOTICE"));

  // Cloudflare appends a suffix when a project name is already taken globally, so the site a repository actually
  // answers on is not always derivable from its slug. `sites.json` records what each project really resolved to, and
  // it is the source of truth for canonical URLs, Open Graph URLs and the links in the README.
  const siteUrl = SITES[slug] ?? `https://${slug}.pages.dev`;
  const repoUrl = `https://github.com/${OWNER}/${slug}`;

  write(repo, "script/Deploy.s.sol", deployScript(hook));
  write(repo, "README.md", readme(hook, {repo: repoUrl, catalogueUrl: CATALOGUE_URL, siteUrl}));
  write(repo, "docs/integrating.md", integratingDoc(hook, {siteUrl}));
  write(repo, "docs/deploying.md", deployingDoc(hook));
  write(repo, "hook.json", `${JSON.stringify(hook, null, 2)}\n`);
  write(repo, "package.json", packageJson(hook));
  emitSite(repo, hook, {siteUrl, repoUrl, catalogueUrl: CATALOGUE_URL});
  write(
    repo,
    ".gitignore",
    `# Foundry
out/
cache/
broadcast/*/dry-run/
.forge-snapshots/

# Node
node_modules/
web/dist/

# Written by script/DeployLocal.s.sol. Names addresses that exist only on the machine that ran it.
web/local.json

# Env and secrets: never commit a key or an RPC with a token in it
.env
.env.*
!.env.example
*.pem
*.key

.DS_Store
*.log
`,
  );
  write(
    repo,
    ".env.example",
    `# A funded deployer on the target chain. Never commit the real value.
PRIVATE_KEY=

# Any RPC for a chain with a Uniswap v4 PoolManager.
RPC_URL=https://mainnet.base.org

# Optional, for --verify.
ETHERSCAN_API_KEY=
`,
  );

  return {hook, repo, files: [...files], flags: claimedFlags(hook)};
}

const args = process.argv.slice(2);
if (args.length > 0) {
  const outIndex = args.indexOf("--out");
  const outRoot = outIndex === -1 ? join(ROOT, "..", "hookforge-spinouts") : args[outIndex + 1];
  const slugs = args.includes("--all") ? Object.keys(manifests()) : args.filter((a) => !a.startsWith("--") && a !== outRoot);

  for (const slug of slugs) {
    const {hook, repo, files} = generate(slug, outRoot);
    console.log(`${hook.slug.padEnd(20)} -> ${repo}  (${files.length} solidity files, ${claimedFlags(hook).length}/14 callbacks)`);
  }
}
