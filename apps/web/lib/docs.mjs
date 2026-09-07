import {esc, h} from "./html.mjs";
import {SITE} from "./layout.mjs";
import {chainName} from "./pages.mjs";

const wrap = (title, lede, body) => h`
<div class="shell layout">
  <article class="prose">
    <h1 style="margin-top:2rem">${esc(title)}</h1>
    <p class="lede" style="color:var(--text-dim);font-size:1.08rem">${lede}</p>
    ${body}
  </article>
  <aside class="side">
    <div class="panel">
      <h3>Documentation</h3>
      <ul style="list-style:none;margin:0;padding:0;display:grid;gap:0.4rem;font-size:0.9rem">
        <li><a href="/docs/">Start here</a></li>
        <li><a href="/docs/sdk/">TypeScript SDK</a></li>
        <li><a href="/docs/mcp/">MCP server</a></li>
        <li><a href="/docs/deploy/">Deploy a hook</a></li>
        <li><a href="/hooks/">Hook catalogue</a></li>
      </ul>
    </div>
    <div class="panel">
      <h3>Source</h3>
      <p style="margin:0;font-size:0.9rem"><a href="${SITE.repo}" rel="noopener">github.com/nirholas/hookforge</a></p>
    </div>
  </aside>
</div>`;

export function startHerePage({chains, shippedCount}) {
  return wrap(
    "Start here",
    h`Everything you need to take a hook from this catalogue and run a pool on it, on any of the ${chains.length} chains Uniswap v4 is deployed to.`,
    h`
<h2>What a hook is</h2>
<p>
  A Uniswap v4 pool is identified by a <code>PoolKey</code>, and one of its five fields is a hook address. Before and
  after every operation on the pool, the protocol calls that address. Which of the fourteen callbacks it calls is not
  configuration and not metadata: Uniswap reads it out of the low fourteen bits of the hook's own address. That is why
  deploying a hook starts by mining a CREATE2 salt, and why you can tell what any hook will do without its source.
</p>

<h2>Install</h2>
<pre><code>npm install @hookforge/sdk viem      # read hooks and pools from TypeScript
npm install @hookforge/registry       # just the manifests, no runtime
claude mcp add hookforge -- npx -y @hookforge/mcp   # the catalogue inside your agent</code></pre>

<p>Or work with the contracts directly:</p>
<pre><code>git clone --recurse-submodules ${SITE.repo}
cd hookforge/contracts &amp;&amp; forge build &amp;&amp; forge test</code></pre>

<h2>Three things that trip people up</h2>

<h3>1. A fee hook needs a dynamic-fee pool</h3>
<p>
  Hooks that price each swap do it by overriding the pool's LP fee, and Uniswap only permits that on a pool
  initialized with the dynamic-fee sentinel <code>0x800000</code>. Initialize with a normal fee tier and the hook
  reverts at <code>afterInitialize</code> rather than silently doing nothing. The SDK's
  <code>dynamicFeePoolKey()</code> sets it for you.
</p>

<h3>2. Parameters are set before the pool exists</h3>
<p>
  Uniswap v4 removed <code>hookData</code> from <code>initialize</code>, so a hook that needs per-pool parameters has
  to be told them out of band. Every configurable hook here exposes <code>configure(key, config)</code>, callable by
  anyone for a pool key whose pool does not exist yet, and never again afterwards. Call it, then initialize.
</p>
<p>
  Someone can configure a key they never intend to initialize. The remedy is local and cheap: pick a different
  <code>tickSpacing</code>, which is a different pool id, and configure that. Configuration is deliberately not
  re-openable, because a mutable configuration would let the same person rewrite the terms of a live pool under its
  liquidity providers.
</p>

<h3>3. The fee is paid to liquidity, not to the hook</h3>
<p>
  When a hook in this catalogue charges more, the extra is an LP fee. It goes to in-range liquidity. None of these
  hooks hold a balance, none of them have an owner, and none of them can be paused. That is a deliberate constraint,
  not an omission: it is what makes them safe to reason about without trusting whoever deployed them.
</p>

<h2>Quickstart: a pool that taxes stale-price arbitrage</h2>
<pre><code>// Foundry. See /docs/deploy/ for deploying the hook itself.
ArbTaxDecayHook hook = ArbTaxDecayHook(0x1A0e586A71F401c2E511c7e6fAf7197112915080); // Base

PoolKey memory key = PoolKey({
    currency0: Currency.wrap(USDC),
    currency1: Currency.wrap(WETH),
    fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

// 0.30% base, up to +0.70% of staleness surcharge, half of it after five quiet minutes.
hook.configure(key, ArbTaxDecayHook.Config({baseFee: 3000, maxSurcharge: 7000, halfLife: 300}));
manager.initialize(key, startingSqrtPriceX96);</code></pre>

<h2>Chains</h2>
<p>${shippedCount} hooks are published with addresses on Base, Arbitrum One, Unichain and Robinhood Chain. The
contracts build and deploy unchanged on every chain with a v4 <code>PoolManager</code>:</p>
<table>
  <thead><tr><th>Chain</th><th>Chain ID</th><th>PoolManager</th></tr></thead>
  <tbody>${chains
    .map(
      (chain) => h`<tr><td>${esc(chainName(chain.slug))}</td><td><code>${chain.chainId}</code></td><td><code>${esc(chain.poolManager)}</code></td></tr>`,
    )
    .join("")}</tbody>
</table>`,
  );
}

export function sdkDocsPage() {
  return wrap(
    "TypeScript SDK",
    h`<code>@hookforge/sdk</code> reads hooks and pools with <a href="https://viem.sh" rel="noopener">viem</a>. Its most useful function works on any v4 pool, not only ours.`,
    h`
<h2>Install</h2>
<pre><code>npm install @hookforge/sdk viem</code></pre>

<h2>Ask an unknown pool what it is</h2>
<pre><code>import {createPublicClient, http} from "viem";
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
hook.permissions.afterSwap; // true
catalogue?.docs;            // https://hookforge.pages.dev/hooks/circuit-breaker</code></pre>

<h2>Decode a hook with no network at all</h2>
<p>
  The permissions come from the address, so this needs no RPC, no ABI and no verified source. It is correct for every
  hook on every chain, including hooks that have nothing to do with this catalogue.
</p>
<pre><code>import {permissionsFromAddress} from "@hookforge/sdk";

permissionsFromAddress("0x4893e7438ee8d2Ee400b7c4d88493f0F51e650C0");
// { beforeSwap: true, afterSwap: true, afterInitialize: true, ... }</code></pre>

<h2>Browse the catalogue</h2>
<pre><code>import {listHooks, findHooks, hookAddress, loadManifest} from "@hookforge/sdk";

findHooks({tag: "mev", chainId: 8453});   // MEV hooks deployed on Base
hookAddress("depeg-shield", 42161);       // its address on Arbitrum One

const manifest = await loadManifest("depeg-shield");
manifest.configure.fields;                // parameters, with types
manifest.limitation;                      // where this hook does not help</code></pre>

<h2>Build a pool key</h2>
<p>
  A <code>PoolKey</code>'s currencies must be sorted, and a fee hook needs the dynamic-fee sentinel.
  <code>dynamicFeePoolKey</code> does both. <code>poolId</code> derives the id exactly as <code>PoolIdLibrary.toId</code>
  does on-chain; the test suite asserts the two agree byte for byte, because a wrong pool id does not throw, it
  silently reads another pool's state.
</p>
<pre><code>import {dynamicFeePoolKey, poolId, formatFee} from "@hookforge/sdk";

const key = dynamicFeePoolKey(usdc, weth, 60, hookAddress("arb-tax-decay", 8453));
poolId(key);        // 0x...
formatFee(3000);    // "0.30%"</code></pre>

<h2>API</h2>
<table>
  <thead><tr><th>Export</th><th>Purpose</th></tr></thead>
  <tbody>
    <tr><td><code>describePool(client, key)</code></td><td>Pool id, hook identity and catalogue entry for any v4 pool.</td></tr>
    <tr><td><code>identifyHook(client, address)</code></td><td>Name, version, spec URI, tags and permissions for any hook.</td></tr>
    <tr><td><code>permissionsFromAddress(address)</code></td><td>The fourteen callback flags. Works offline.</td></tr>
    <tr><td><code>poolId(key)</code></td><td><code>keccak256(abi.encode(key))</code>.</td></tr>
    <tr><td><code>listHooks()</code>, <code>findHooks(filter)</code>, <code>getHookEntry(slug)</code></td><td>The catalogue.</td></tr>
    <tr><td><code>hookAddress(slug, chainId)</code></td><td>A deployment address.</td></tr>
    <tr><td><code>loadManifest(slug)</code></td><td>Full manifest including ABI, parameters, prior art and limitations.</td></tr>
    <tr><td><code>dynamicFeePoolKey(a, b, tickSpacing, hooks)</code></td><td>A sorted key with the dynamic-fee flag set.</td></tr>
  </tbody>
</table>`,
  );
}

export function mcpDocsPage() {
  return wrap(
    "MCP server",
    h`<code>@hookforge/mcp</code> puts the catalogue inside your coding agent. No API key, no network access, no telemetry: the data ships in the package.`,
    h`
<h2>Install</h2>
<pre><code>claude mcp add hookforge -- npx -y @hookforge/mcp</code></pre>
<p>Any MCP client, via config:</p>
<pre><code>{
  "mcpServers": {
    "hookforge": { "command": "npx", "args": ["-y", "@hookforge/mcp"] }
  }
}</code></pre>

<h2>Tools</h2>
<table>
  <thead><tr><th>Tool</th><th>Use it for</th></tr></thead>
  <tbody>
    <tr><td><code>search_hooks</code></td><td>The problem in plain language. Ranked matches back, with the terms that matched so the reasoning is visible. Start here.</td></tr>
    <tr><td><code>list_hooks</code></td><td>The whole catalogue, filtered by tag, family or chain, plus the taxonomy.</td></tr>
    <tr><td><code>get_hook</code></td><td>One hook in full: mechanism, prior art, limitation, parameters, permissions, errors, addresses, optionally the ABI.</td></tr>
    <tr><td><code>decode_hook_address</code></td><td>What a hook address will do, from the address itself. Works on hooks nobody published.</td></tr>
    <tr><td><code>get_deployment</code></td><td>A hook's address on a chain, and that chain's <code>PoolManager</code>.</td></tr>
    <tr><td><code>list_chains</code></td><td>Every chain with a v4 deployment HookForge knows about.</td></tr>
  </tbody>
</table>

<h2>Why search is keyword, not embedding</h2>
<p>
  <code>search_hooks</code> scores tag matches highest, then name, family and summary, and returns the matched terms
  next to every result. An embedding index would score better on recall. But an agent recommending a financial
  mechanism to someone should be able to show its work, and a catalogue of fifty entries does not need vector search
  to find the right one.
</p>

<h2>Why <code>decode_hook_address</code> needs no RPC</h2>
<p>
  Uniswap v4 decides which callbacks to invoke by masking the low fourteen bits of the hook address. Those bits are
  the mechanism, not a description of it, so decoding them is authoritative for any hook anywhere, verified source or
  not. The tool is explicit that absence from this catalogue is not a safety judgement.
</p>`,
  );
}

export function deployDocsPage({chains}) {
  return wrap(
    "Deploy a hook",
    h`Mining a CREATE2 salt, broadcasting, and publishing the address, on any of the ${chains.length} chains with a Uniswap v4 pool manager.`,
    h`
<h2>Why deployment is not just <code>new Hook()</code></h2>
<p>
  Uniswap reads a hook's permissions from the low fourteen bits of its address. A hook that implements
  <code>beforeSwap</code> but does not live at an address whose bit 7 is set will simply never be called, and the
  constructor's own validation rejects the deployment rather than letting that happen silently. So the first step is
  always to search for a salt whose CREATE2 address has the right bits.
</p>

<h2>Deploy the catalogue</h2>
<pre><code>cd contracts
export PRIVATE_KEY=0x...            # or use --account / --ledger

forge script script/DeployHooks.s.sol \\
  --rpc-url https://mainnet.base.org \\
  --broadcast --verify --gas-limit 30000000000</code></pre>

<p>
  The script mines a salt per hook, deploys through the deterministic CREATE2 proxy, asserts the deployed contract
  answers to its own name, and writes <code>deployments/&lt;chainId&gt;.json</code>. Re-running is safe: a hook already
  at its mined address is skipped, so the same command adds one new hook to a chain that already has the others.
</p>

<h2>The gas-limit trap</h2>
<p>
  Salt mining is a loop, and how long it runs depends on the chain, because the pool manager address is part of the
  init code and each chain therefore searches a different space. On some chains the search exceeds the default script
  gas limit and fails with <code>EvmError: OutOfGas</code> raised inside the miner, which reads like a bug in the hook
  and is not one. <code>--gas-limit 30000000000</code> fixes it and costs nothing, because mining is a view loop that
  never touches the chain.
</p>

<h2>Publish the addresses</h2>
<pre><code>node packages/registry/scripts/build.mjs</code></pre>
<p>
  The generator rebuilds every manifest from the contracts and folds in the new addresses. It also decodes the
  permissions from each published address, so a hook mined against the wrong flags cannot reach the registry: the SDK
  test suite asserts every published address encodes exactly the permissions its manifest claims.
</p>

<h2>Submit to Uniswap's hooklist</h2>
<p>
  Uniswap keeps a <a href="https://github.com/Uniswap/hooklist" rel="noopener">public registry of v4 hook
  deployments</a>. Open an issue there with the chain and the hook address; their workflow pulls the verified source,
  decodes the flags and opens the pull request. Listing there is discovery, not an endorsement, and it does not put a
  hook on Uniswap's routing allowlist.
</p>

<h2>Supported chains</h2>
<table>
  <thead><tr><th>Chain</th><th>Chain ID</th><th>PoolManager</th></tr></thead>
  <tbody>${chains
    .map(
      (chain) => h`<tr><td>${esc(chainName(chain.slug))}</td><td><code>${chain.chainId}</code></td><td><code>${esc(chain.poolManager)}</code></td></tr>`,
    )
    .join("")}</tbody>
</table>`,
  );
}
