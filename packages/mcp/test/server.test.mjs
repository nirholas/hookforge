import {test, before, after} from "node:test";
import assert from "node:assert/strict";
import {Client} from "@modelcontextprotocol/sdk/client/index.js";
import {StdioClientTransport} from "@modelcontextprotocol/sdk/client/stdio.js";
import {fileURLToPath} from "node:url";

let client;

/** Talks to the real server over a real stdio transport: nothing here is stubbed. */
before(async () => {
  client = new Client({name: "hookforge-tests", version: "1.0.0"});
  // Resolve the server relative to this file, so the suite runs the same from the package directory (npm test
  // inside the workspace) and from the repository root (npm test --workspaces).
  const serverPath = fileURLToPath(new URL("../dist/server.js", import.meta.url));
  await client.connect(new StdioClientTransport({command: "node", args: [serverPath]}));
});

after(async () => {
  await client?.close();
});

const call = async (name, args = {}) => JSON.parse((await client.callTool({name, arguments: args})).content[0].text);

test("the server advertises every tool", async () => {
  const {tools} = await client.listTools();
  const names = tools.map((tool) => tool.name).sort();
  assert.deepEqual(names, [
    "decode_hook_address",
    "get_deployment",
    "get_hook",
    "list_chains",
    "list_hooks",
    "search_hooks",
  ]);

  for (const tool of tools) {
    assert.ok(tool.description.length > 40, `${tool.name} needs a description an agent can route on`);
  }
});

test("search finds a hook from a problem stated in plain language", async () => {
  const result = await call("search_hooks", {query: "stop snipers buying in the first block of my launch"});
  assert.ok(result.matches.length > 0, "no match for a launch-sniping question");
  assert.equal(result.matches[0].slug, "anti-snipe-ramp");
  assert.ok(result.matches[0].matched.length > 0, "a match must say why it matched");
});

test("search explains itself when nothing matches", async () => {
  const result = await call("search_hooks", {query: "zzzzq wwwwx"});
  assert.deepEqual(result.matches, []);
  assert.ok(result.hint.length > 0);
});

test("get_hook returns prior art and limitations, and omits the ABI unless asked", async () => {
  const hook = await call("get_hook", {slug: "circuit-breaker"});
  assert.equal(hook.name, "CircuitBreaker");
  assert.ok(hook.priorArt.length > 40, "every hook states what already existed");
  assert.ok(hook.limitation.length > 40, "every hook states where it does not help");
  assert.equal(hook.abi, undefined);

  const withAbi = await call("get_hook", {slug: "circuit-breaker", includeAbi: true});
  assert.ok(Array.isArray(withAbi.abi) && withAbi.abi.length > 0);
});

test("get_hook lists the available slugs when given a bad one", async () => {
  const result = await call("get_hook", {slug: "not-a-hook"});
  assert.match(result.error, /No hook with slug/);
  assert.ok(result.available.includes("circuit-breaker"));
});

test("decode_hook_address works on an address the catalogue has never seen", async () => {
  // Low bits 0x10c0: AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP.
  const result = await call("decode_hook_address", {address: "0xdeadBEEFdeadBEEFdeadBEEFdeadbeef000010c0"});
  assert.deepEqual(result.callbacks.sort(), ["afterInitialize", "afterSwap", "beforeSwap"]);
  assert.equal(result.inCatalogue, null);
  assert.equal(result.isHook, true);
});

test("decode_hook_address recognises a published deployment", async () => {
  const {address} = await call("get_deployment", {slug: "circuit-breaker", chainId: 8453});
  const result = await call("decode_hook_address", {address});
  assert.equal(result.inCatalogue.slug, "circuit-breaker");
  assert.equal(result.permissions.afterSwap, true);
});

test("get_deployment resolves both the hook and the PoolManager", async () => {
  const result = await call("get_deployment", {slug: "arb-tax-decay", chainId: 4663});
  assert.equal(result.chain, "robinhood");
  assert.match(result.address, /^0x[0-9a-fA-F]{40}$/);
  assert.equal(result.poolManager, "0x8366a39CC670B4001A1121B8F6A443A643e40951");
});

test("list_hooks exposes the taxonomy and filters on it", async () => {
  const all = await call("list_hooks");
  assert.ok(all.count > 0);
  assert.ok(all.families.length > 0);
  assert.ok(all.tags.includes("mev"));

  const risk = await call("list_hooks", {family: "Risk"});
  assert.ok(risk.hooks.every((hook) => hook.family === "Risk"));

  const onBase = await call("list_hooks", {chainId: 8453});
  assert.ok(onBase.count > 0, "no hook is published on Base");
  assert.ok(onBase.count <= all.count);
  assert.ok(onBase.hooks.every((hook) => all.hooks.some((h) => h.slug === hook.slug)));
});

test("list_chains covers the four target chains", async () => {
  const {chains} = await call("list_chains");
  const ids = chains.map((chain) => chain.chainId);
  for (const id of [8453, 42161, 130, 4663]) assert.ok(ids.includes(id), `chain ${id} missing`);
});
