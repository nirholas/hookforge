import {esc, h} from "../html.mjs";
import {page, SITE} from "../layout.mjs";

/** Wraps doc body HTML in the shared shell, with a table of contents built from the headings it declares. */
function doc({slug, title, description, body, toc, assets}) {
  const path = slug === "" ? "/docs/" : `/docs/${slug}/`;

  const jsonLd = [
    {
      "@context": "https://schema.org",
      "@type": "TechArticle",
      headline: title,
      description,
      url: `${SITE.url}${path}`,
      isPartOf: {"@type": "WebSite", name: SITE.name, url: SITE.url},
      license: "https://opensource.org/licenses/MIT",
    },
  ];

  const wrapped = h`
<article class="shell layout">
  <div class="prose" style="padding-top:3rem">
    <p class="eyebrow"><a href="/docs/">Docs</a></p>
    ${body}
  </div>
  <aside class="side">
    <div class="panel">
      <h4>On this page</h4>
      <ul>${toc.map(([id, label]) => `<li><a href="#${esc(id)}">${esc(label)}</a></li>`).join("")}</ul>
    </div>
    <div class="panel">
      <h4>Documentation</h4>
      <ul>
        <li><a href="/docs/">Start here</a></li>
        <li><a href="/docs/sdk/">TypeScript SDK</a></li>
        <li><a href="/docs/mcp/">MCP server</a></li>
        <li><a href="/docs/metadata/">On-chain metadata</a></li>
        <li><a href="/docs/deploy/">Deploy a hook</a></li>
        <li><a href="/docs/agents/">For agents</a></li>
      </ul>
    </div>
  </aside>
</article>`;

  return page({title: `${title} | HookForge`, description, path, assets, body: wrapped, jsonLd, ogImage: `${SITE.url}/og/docs.png`});
}

export function startHere({assets, hooks}) {
  return doc({
    slug: "",
    title: "Start here",
    description:
      "How the HookForge Uniswap v4 hooks are built, how to run them locally, how to use one in a pool, and how the catalogue is generated from the Solidity source.",
    assets,
    toc: [
      ["what", "What this is"],
      ["run", "Run it locally"],
      ["use", "Use a hook in a pool"],
      ["shape", "The shape of a hook"],
      ["trust", "What you are trusting"],
    ],
    body: h`
<h1>Start here</h1>
<p>
  HookForge is a catalogue of Uniswap v4 hooks for mechanisms that did not have one. There are
  <strong>${hooks.length}</strong> shipped: contract, tests, deploy script, manifest and documentation, all in
  <a href="${esc(SITE.repo)}" rel="noopener">one repository</a>, MIT licensed.
</p>

<h2 id="what">What this is</h2>
<p>
  A hook is a contract that Uniswap v4 calls at specific points in a pool's life. There are fourteen such points, and
  which ones a hook participates in is encoded in the low fourteen bits of the hook's own address, which is why hook
  addresses all end in the same few patterns and why deploying one involves mining a CREATE2 salt.
</p>
<p>
  Most published hooks re-implement something that already worked. Every hook here was checked against the roughly 140
  published hooks and hackathon submissions first, and each one carries its prior art and its limitation in its own
  NatSpec, where they end up on this site because the site is generated from the source.
</p>

<h2 id="run">Run it locally</h2>
<pre><code>git clone --recurse-submodules ${esc(SITE.repo)}
cd hookforge

# Contracts: Foundry 1.7+, Solidity 0.8.26, EVM version cancun.
cd contracts && forge build && forge test

# Packages: the SDK, the registry generator and the MCP server.
cd .. && npm install && npm test</code></pre>
<p>
  <code>npm run build:registry</code> regenerates every manifest from <code>contracts/out</code>, so after changing a
  hook's NatSpec the site and the SDK follow automatically.
</p>

<h2 id="use">Use a hook in a pool</h2>
<p>
  Two calls. Fix the hook's parameters for a pool key that does not exist yet, then initialize the pool. The hook
  rejects a pool it was never configured for, so a misconfigured pool cannot come into existence.
</p>
<pre><code>// Solidity
hook.configure(key, ArbTaxDecayHook.Config({baseFee: 500, maxSurcharge: 9500, halfLife: 600}));
poolManager.initialize(key, startingSqrtPriceX96);</code></pre>
<p>
  Note the fee-bearing hooks require the pool's <code>fee</code> field to be
  <code>LPFeeLibrary.DYNAMIC_FEE_FLAG</code>. The SDK's <code>poolKeyFor({dynamicFee: true})</code> sets it for you, and
  the hook reverts at initialization if you forget.
</p>

<h2 id="shape">The shape of a hook</h2>
<p>
  Every hook extends one of two bases. <code>ForgeFeeHook</code> is for hooks that price each swap by overriding the LP
  fee: it builds on OpenZeppelin's audited <code>BaseOverrideFee</code>, so the fee goes to in-range liquidity and the
  hook never touches the money. <code>ForgeHook</code> is for everything else. Both mix in
  <a href="/docs/metadata/"><code>IHookMetadata</code></a>.
</p>
<p>
  Per-pool parameters come through <code>configure</code> rather than <code>hookData</code>, because v4 removed
  <code>hookData</code> from <code>initialize</code>. Anyone may configure a pool key whose pool does not exist yet, and
  nobody may change it afterwards. A griefer who configures a key they do not intend to initialize costs the real
  creator one different <code>tickSpacing</code>, and nothing else.
</p>

<h2 id="trust">What you are trusting</h2>
<div class="callout callout--warn">
  <h3>These contracts are unaudited</h3>
  <p>
    They are written to an audited shape, built on OpenZeppelin's audited hook bases, and tested against a real
    <code>PoolManager</code>, but no third party has reviewed them. Read the limitation section on a hook's page before
    putting money behind it, and treat a deterministic address as a reservation rather than a deployment.
  </p>
</div>
<p>
  What you are not trusting: there are no owners, no pause switches, no upgrade paths and no privileged roles anywhere
  in the catalogue. A hook's parameters are fixed before its pool exists, so nobody can change the terms under liquidity
  that already committed to them.
</p>`,
  });
}

export function sdkDoc({assets}) {
  return doc({
    slug: "sdk",
    title: "TypeScript SDK",
    description:
      "@hookforge/sdk: the hook catalogue, the deterministic address book, pool-key construction, pool id hashing and hook permission decoding, with no runtime dependencies.",
    assets,
    toc: [
      ["install", "Install"],
      ["catalogue", "Query the catalogue"],
      ["addresses", "Resolve an address"],
      ["keys", "Build a pool key"],
      ["decode", "Decode any hook address"],
    ],
    body: h`
<h1>TypeScript SDK</h1>
<p>
  <code>@hookforge/sdk</code> ships the generated catalogue, the address book and the small amount of v4 maths a client
  needs, with no runtime dependencies. It is the same data the website and the MCP server are built from.
</p>

<h2 id="install">Install</h2>
<pre><code>npm i @hookforge/sdk</code></pre>

<h2 id="catalogue">Query the catalogue</h2>
<pre><code>import {hooks, getHook, hooksByTag, hooksByFamily} from "@hookforge/sdk";

hooks.length;                       // every shipped hook
getHook("depeg-shield");            // one manifest summary
hooksByTag("mev");                  // everything tagged mev
hooksByFamily("Risk");              // everything in the risk family</code></pre>

<h2 id="addresses">Resolve an address</h2>
<p>
  <code>hookAddress</code> returns the address for a hook on a chain, or <code>null</code> when that hook has no entry
  there. Check <code>status</code> before treating one as live: a <code>deterministic</code> address is where the hook
  will be, not where it is.
</p>
<pre><code>import {hookAddress, deploymentsFor, poolManagerFor} from "@hookforge/sdk";

hookAddress("arb-tax-decay", 8453);      // Base
deploymentsFor("arb-tax-decay");         // every chain, each with a status
poolManagerFor(4663);                    // Robinhood Chain PoolManager</code></pre>

<h2 id="keys">Build a pool key</h2>
<p>
  <code>poolKeyFor</code> sorts the currencies the way v4 requires, sets the dynamic-fee flag when the hook needs it, and
  returns a key whose <code>poolId</code> matches <code>keccak256(abi.encode(key))</code> byte for byte. That equality is
  asserted in the SDK's tests against values produced by Solidity.
</p>
<pre><code>import {poolKeyFor, poolId} from "@hookforge/sdk";

const key = poolKeyFor({
  hook: hookAddress("depeg-shield", 42161),
  currencyA: USDC, currencyB: USDT,
  tickSpacing: 1, dynamicFee: true,
});
poolId(key); // 0x…</code></pre>

<h2 id="decode">Decode any hook address</h2>
<p>
  This works on any v4 hook, not only ours: the flags are in the address, so the answer needs no network call and no
  registry.
</p>
<pre><code>import {permissionsOf} from "@hookforge/sdk";

permissionsOf("0x1A0e586A71F401c2E511c7e6fAf7197112915080");
// { beforeSwap: true, afterInitialize: true, ... }</code></pre>`,
  });
}

export function mcpDoc({assets}) {
  return doc({
    slug: "mcp",
    title: "MCP server",
    description:
      "@hookforge/mcp: a Model Context Protocol server that lets a coding agent search Uniswap v4 hooks by problem, read a hook's parameters and prior art, resolve addresses and decode what any hook address does.",
    assets,
    toc: [
      ["install", "Add it to a client"],
      ["tools", "The tools"],
      ["why", "Why an MCP server"],
    ],
    body: h`
<h1>MCP server</h1>
<p>
  <code>@hookforge/mcp</code> gives a coding agent the same view of the catalogue a developer gets from this site:
  search by the problem rather than the name, read a hook's parameters, prior art and limitations, resolve its address
  on a chain, and decode what any hook address on any chain will actually do.
</p>

<h2 id="install">Add it to a client</h2>
<pre><code>{
  "mcpServers": {
    "hookforge": {"command": "npx", "args": ["-y", "@hookforge/mcp"]}
  }
}</code></pre>
<p>For Claude Code, one command:</p>
<pre><code>claude mcp add hookforge -- npx -y @hookforge/mcp</code></pre>

<h2 id="tools">The tools</h2>
<table class="addresses">
  <thead><tr><th>Tool</th><th>What it answers</th></tr></thead>
  <tbody>
    <tr><td><code>search_hooks</code></td><td>"My pool gets arbitraged after every quiet period." Ranked matches, with the terms that matched.</td></tr>
    <tr><td><code>list_hooks</code></td><td>The whole catalogue, filterable by tag, family or chain.</td></tr>
    <tr><td><code>get_hook</code></td><td>One hook in full: description, prior art, limitation, parameters, errors, ABI.</td></tr>
    <tr><td><code>get_deployment</code></td><td>A hook's address on a chain, plus that chain's <code>PoolManager</code>.</td></tr>
    <tr><td><code>decode_hook_address</code></td><td>Which of the fourteen callbacks any hook address claims, ours or anyone's.</td></tr>
    <tr><td><code>list_chains</code></td><td>Every chain in the address book with its <code>PoolManager</code>.</td></tr>
  </tbody>
</table>

<h2 id="why">Why an MCP server</h2>
<p>
  An agent asked to add a hook to a pool has two bad options today: guess from a model's training data, which is stale
  and full of hooks that were never deployed, or scrape a website that was written for humans. Both produce plausible
  addresses that are wrong.
</p>
<p>
  The server answers from the generated registry, so an agent gets the same facts as the site, including the ones a
  scrape loses: whether an address is live or merely deterministic, what a parameter's units are, and what the hook
  explicitly does not do.
</p>`,
  });
}

export function metadataDoc({assets}) {
  return doc({
    slug: "metadata",
    title: "On-chain metadata",
    description:
      "IHookMetadata: four view functions that let a Uniswap v4 hook describe itself on-chain, so indexers, wallets, routers and agents can classify a pool without a curated list.",
    assets,
    toc: [
      ["problem", "The problem"],
      ["interface", "The interface"],
      ["manifest", "The manifest"],
      ["adopt", "Adopting it"],
    ],
    body: h`
<h1>On-chain metadata</h1>

<h2 id="problem">The problem</h2>
<p>
  A hook is an address in a <code>PoolKey</code>. Nothing about that address tells an indexer, a wallet, a router or an
  agent what the pool actually does. The fourteen permission bits say <em>where</em> the hook intervenes but nothing
  about <em>what</em> it does there: <code>beforeSwap</code> is equally consistent with a fee discount and a total
  block on trading.
</p>
<p>
  So hook discovery today is a curated list maintained by hand, and everything not on that list is an unknown address
  that tooling either ignores or renders as a warning.
</p>

<h2 id="interface">The interface</h2>
<p>
  Four view functions, all answerable from constants, costing no storage and about 200 gas to query. Every HookForge
  hook implements it, and it is deliberately small enough that any hook can.
</p>
<pre><code>interface IHookMetadata {
    function hookName() external view returns (string memory);
    function hookVersion() external view returns (string memory);
    function specURI() external view returns (string memory);
    function hookTags() external view returns (string[] memory);
}</code></pre>
<p>Ask any HookForge address what it is:</p>
<pre><code>cast call $HOOK "hookName()(string)"
cast call $HOOK "hookTags()(string[])"
cast call $HOOK "specURI()(string)"</code></pre>
<p>
  It is discoverable through ERC-165, so a caller can ask whether an arbitrary hook supports it before calling.
</p>

<h2 id="manifest">The manifest</h2>
<p>
  <code>specURI()</code> points at a machine-readable manifest carrying what does not belong on-chain: the full
  description, the parameter list with units, the prior art, the limitation, the errors, the ABI and the deployments.
  Manifests follow <a href="/schema/hook-manifest.json">one schema</a> and are served at stable URLs:
</p>
<pre><code>${SITE.url}/schema/hooks/&lt;slug&gt;.json</code></pre>
<p>
  Each is generated from the contract, so a manifest cannot describe a hook as something it is not.
</p>

<h2 id="adopt">Adopting it</h2>
<p>
  <code>IHookMetadata</code> is MIT licensed and has no dependency on anything else here. Copy the interface, return
  four constants, and point <code>specURI</code> anywhere you like. It costs nothing and it makes your hook legible to
  every tool that learns to ask.
</p>
<p>
  Hooks in this catalogue are also submitted to <a href="${esc(SITE.hooklist ?? "https://github.com/Uniswap/hooklist")}" rel="noopener">Uniswap's hooklist</a>,
  which remains the right place for a curated allowlist. The two are complements: a list says which hooks are blessed,
  self-description says what an unlisted hook claims to be.
</p>`,
  });
}

export function deployDoc({assets}) {
  return doc({
    slug: "deploy",
    title: "Deploy a hook",
    description:
      "How to deploy a HookForge Uniswap v4 hook: mining the CREATE2 salt so the address encodes the permission flags, deploying deterministically across chains, and verifying the result.",
    assets,
    toc: [
      ["why", "Why deployment is unusual"],
      ["run", "Running the script"],
      ["verify", "Verify and register"],
    ],
    body: h`
<h1>Deploy a hook</h1>

<h2 id="why">Why deployment is unusual</h2>
<p>
  Uniswap v4 reads a hook's permissions from the low fourteen bits of its address, and the <code>PoolManager</code>
  rejects a pool whose hook address does not match the permissions the hook declares. So you cannot deploy a hook to
  whatever address you happen to get: you mine a CREATE2 salt until the resulting address has the right bits, then
  deploy with that salt through a deterministic factory.
</p>
<p>
  A useful consequence is that the same hook lands on the same address on every chain, so the address book is
  computable rather than recorded.
</p>

<h2 id="run">Running the script</h2>
<pre><code>cd contracts

# Dry run: mines every salt and prints the addresses without sending anything.
forge script script/DeployHooks.s.sol --rpc-url $BASE_RPC_URL

# For real.
forge script script/DeployHooks.s.sol \\
  --rpc-url $BASE_RPC_URL --broadcast --verify</code></pre>
<p>
  The script writes <code>contracts/deployments/&lt;chainId&gt;.json</code>, which the registry generator reads. Run
  <code>npm run build:registry</code> afterwards and every manifest, the SDK and this site pick the addresses up, with
  <code>status</code> flipping from <code>deterministic</code> to a live deployment.
</p>
<p>
  You need a funded deployer key on the target chain. Nothing in this repository ships one.
</p>

<h2 id="verify">Verify and register</h2>
<p>
  Verify the source on the chain's explorer as part of the deploy (<code>--verify</code> above), then submit the hook to
  <a href="https://github.com/Uniswap/hooklist" rel="noopener">Uniswap's hooklist</a>, which takes a chain and an
  address and derives the rest from verified source.
</p>
<div class="callout">
  <h3>Being on a list is not an endorsement</h3>
  <p>
    Uniswap's registry is explicit that submitting a hook does not make it allowlisted for routing, and this catalogue
    is explicit that its contracts are unaudited. Both statements are worth repeating to anyone who reads a listing as
    a safety claim.
  </p>
</div>`,
  });
}

export function agentsDoc({assets, hooks}) {
  return doc({
    slug: "agents",
    title: "For agents",
    description:
      "Machine-readable entry points to the HookForge Uniswap v4 catalogue: MCP server, llms.txt, registry JSON, per-hook manifests, and on-chain self-description via IHookMetadata.",
    assets,
    toc: [
      ["mcp", "MCP"],
      ["json", "JSON endpoints"],
      ["onchain", "On-chain"],
      ["rules", "Rules of the road"],
    ],
    body: h`
<h1>For agents</h1>
<p>
  This catalogue is built to be read by software as much as by people. Everything a page here shows is available as
  JSON at a stable URL, as a tool call, or as an <code>eth_call</code>.
</p>

<h2 id="mcp">MCP</h2>
<pre><code>claude mcp add hookforge -- npx -y @hookforge/mcp</code></pre>
<p>
  Six tools: <code>search_hooks</code>, <code>list_hooks</code>, <code>get_hook</code>, <code>get_deployment</code>,
  <code>decode_hook_address</code>, <code>list_chains</code>. See <a href="/docs/mcp/">the MCP page</a>.
</p>

<h2 id="json">JSON endpoints</h2>
<table class="addresses">
  <thead><tr><th>URL</th><th>Contents</th></tr></thead>
  <tbody>
    <tr><td><a href="/api/hooks.json"><code>/api/hooks.json</code></a></td><td>Every hook: slug, name, family, summary, tags, deployments with status.</td></tr>
    <tr><td><a href="/api/chains.json"><code>/api/chains.json</code></a></td><td>Chain id and <code>PoolManager</code> for every supported chain.</td></tr>
    <tr><td><code>/schema/hooks/&lt;slug&gt;.json</code></td><td>One hook in full, including ABI, errors, parameters, prior art and limitation.</td></tr>
    <tr><td><a href="/schema/hook-manifest.json"><code>/schema/hook-manifest.json</code></a></td><td>JSON Schema the manifests validate against.</td></tr>
    <tr><td><a href="/llms.txt"><code>/llms.txt</code></a></td><td>The catalogue as plain text, for a model reading the site directly.</td></tr>
    <tr><td><a href="/llms-full.txt"><code>/llms-full.txt</code></a></td><td>Every hook's full description, prior art and limitation in one file.</td></tr>
  </tbody>
</table>

<h2 id="onchain">On-chain</h2>
<p>
  You do not need any of the above to identify a HookForge hook. Ask it:
</p>
<pre><code>cast call $HOOK "hookName()(string)"
cast call $HOOK "specURI()(string)"</code></pre>
<p>See <a href="/docs/metadata/">on-chain metadata</a> for the interface and its ERC-165 id.</p>

<h2 id="rules">Rules of the road</h2>
<div class="callout callout--warn">
  <h3>Three things worth encoding in your agent</h3>
  <p>
    <strong>A deterministic address is not a deployment.</strong> Every deployment record carries a <code>status</code>.
    If it says <code>deterministic</code>, there is no code there yet; do not send funds to it and do not tell a user it
    is live.
  </p>
  <p>
    <strong>These contracts are unaudited.</strong> Every manifest carries a <code>limitation</code> field written by
    the author saying where the hook does not help. Surface it rather than summarising it away.
  </p>
  <p>
    <strong>Fee hooks need a dynamic-fee pool.</strong> ${hooks.filter((hook) => hook.properties?.dynamicFee).length} of
    the ${hooks.length} shipped hooks require the pool's fee field to be the dynamic-fee flag, and revert at
    initialization otherwise. The SDK's <code>poolKeyFor</code> handles it.
  </p>
</div>`,
  });
}
