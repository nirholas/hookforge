import {copyable, esc, h, prose} from "./html.mjs";
import {SITE} from "./layout.mjs";

const FLAG_ORDER = [
  "beforeInitialize",
  "afterInitialize",
  "beforeAddLiquidity",
  "afterAddLiquidity",
  "beforeRemoveLiquidity",
  "afterRemoveLiquidity",
  "beforeSwap",
  "afterSwap",
  "beforeDonate",
  "afterDonate",
  "beforeSwapReturnsDelta",
  "afterSwapReturnsDelta",
  "afterAddLiquidityReturnsDelta",
  "afterRemoveLiquidityReturnsDelta",
];

const CHAIN_NAMES = {
  ethereum: "Ethereum",
  optimism: "OP Mainnet",
  bnb: "BNB Chain",
  unichain: "Unichain",
  polygon: "Polygon",
  monad: "Monad",
  xlayer: "X Layer",
  worldchain: "World Chain",
  soneium: "Soneium",
  tempo: "Tempo",
  megaeth: "MegaETH",
  robinhood: "Robinhood Chain",
  base: "Base",
  arbitrum: "Arbitrum One",
  avalanche: "Avalanche",
  celo: "Celo",
  ink: "Ink",
  zora: "Zora",
};

export const chainName = (slug) => CHAIN_NAMES[slug] ?? slug;

/** One catalogue card. Shipped hooks link to their page; planned ones say so plainly rather than pretending. */
function card(entry) {
  const haystack = `${entry.name} ${entry.family} ${entry.summary} ${(entry.tags ?? []).join(" ")}`.toLowerCase();
  const tags = entry.tags ?? [];
  const inner = h`
      <span class="card__family">${esc(entry.family)}</span>
      <h3 class="card__name">${esc(entry.name)}</h3>
      <p class="card__summary">${esc(entry.summary)}</p>
      <div class="card__tags">${tags.map((tag) => `<span class="tag">${esc(tag)}</span>`).join("")}${
        entry.shipped ? "" : '<span class="tag">planned</span>'
      }</div>`;

  return entry.shipped
    ? h`<a class="card" data-haystack="${esc(haystack)}" data-tags="${esc(tags.join(","))}" href="/hooks/${esc(entry.slug)}/">${inner}</a>`
    : h`<div class="card card--soon" data-haystack="${esc(haystack)}" data-tags="${esc(tags.join(","))}">${inner}</div>`;
}

/** The catalogue grid with its search box and tag chips. */
function catalogue(entries, tags) {
  return h`
    <div class="filters">
      <input type="search" data-search placeholder="Search fifty hooks by name, mechanism or problem  (press /)" aria-label="Search hooks">
      ${tags.map((tag) => h`<button class="chip" type="button" data-tag="${esc(tag)}" aria-pressed="false">${esc(tag)}</button>`).join("")}
      <span class="tag"><span data-count>${entries.length}</span> shown</span>
    </div>
    <div class="grid" data-catalogue>${entries.map(card).join("\n")}</div>
    <p data-empty hidden style="color:var(--text-dim);padding:2rem 0">
      Nothing matches that. Clear the search, or browse <a href="/hooks/">the whole catalogue</a>.
    </p>`;
}

export function homePage({entries, tags, shippedCount, chains}) {
  const families = [...new Set(entries.map((entry) => entry.family))];

  return h`
<section class="hero">
  <canvas class="hero__canvas" data-hero aria-hidden="true"></canvas>
  <div class="shell hero__inner">
    <span class="eyebrow">Uniswap v4</span>
    <h1>Fifty hooks<br>nobody has built.</h1>
    <p class="lede">
      Uniswap v4 turned the automated market maker into a platform, and most of what has been built on it so far
      re-implements something that already worked. HookForge is a catalogue of the mechanisms that are missing. Every
      hook is checked against the published prior art before it is written, states in its own source what already
      existed and where its idea runs out, and ships with tests, a deployment script and a client.
    </p>
    <div class="cta-row">
      <a class="btn btn--primary" href="/hooks/">Browse the catalogue</a>
      <a class="btn" href="/docs/">Start building</a>
      <a class="btn" href="${SITE.repo}" rel="noopener">GitHub</a>
    </div>
    <dl class="stats">
      <div class="stat"><dt>Hooks shipped</dt><dd>${shippedCount}</dd></div>
      <div class="stat"><dt>In the catalogue</dt><dd>${entries.length}</dd></div>
      <div class="stat"><dt>Families</dt><dd>${families.length}</dd></div>
      <div class="stat"><dt>Chains supported</dt><dd>${chains.length}</dd></div>
    </dl>
  </div>
</section>

<section class="shell" style="padding: 3rem 0 1rem;">
  <div class="prose">
    <h2 style="margin-top:0">Hooks that describe themselves</h2>
    <p>
      A hook is an address in a pool key. Nothing about that address tells an indexer, a wallet, a router or an agent
      what the pool actually does, which is why hook discovery today is a list maintained by hand.
    </p>
    <p>
      Every hook here answers for itself. It implements four view functions returning a name, a version, a tag list and
      a URI pointing at its machine-readable manifest, so one <code>eth_call</code> against any HookForge address tells
      you what it is with no registry in the loop. The permissions do not even need that: Uniswap decides which
      callbacks to invoke by masking the low fourteen bits of the hook's address, so
      <a href="/docs/sdk/">the SDK</a> and <a href="/docs/mcp/">the MCP server</a> can decode what any hook on any
      chain will do, offline, whether or not its source was ever verified.
    </p>
  </div>
</section>

<section class="shell" style="padding: 2rem 0 5rem;">
  <h2>The catalogue</h2>
  ${catalogue(entries, tags)}
</section>`;
}

export function hooksIndexPage({entries, tags, shippedCount}) {
  return h`
<section class="shell" style="padding: 3rem 0 0;">
  <div class="prose">
    <h1 style="margin-bottom:0.3em">The catalogue</h1>
    <p class="lede" style="color:var(--text-dim)">
      ${shippedCount} of ${entries.length} shipped. Each shipped hook has a page with its mechanism, the prior art it
      is measured against, where it does not help, its parameters and its address on every chain.
    </p>
  </div>
  ${catalogue(entries, tags)}
</section>
<div style="height:4rem"></div>`;
}

/** The permission grid: fourteen flags, lit ones first-class, dark ones still listed so the shape is legible. */
function flagGrid(permissions) {
  if (!permissions) return "";
  return h`<div class="flags">${FLAG_ORDER.map(
    (flag) => h`<span class="flag ${permissions[flag] ? "flag--on" : ""}">${esc(flag)}</span>`,
  ).join("")}</div>`;
}

export function hookPage({manifest}) {
  const {permissions, configure, deployments, errors} = manifest;
  const primary = deployments[0];

  const sdkSample = `import {createPublicClient, http} from "viem";
import {base} from "viem/chains";
import {describePool, hookAddress, dynamicFeePoolKey} from "@hookforge/sdk";

const client = createPublicClient({chain: base, transport: http()});
const hook = hookAddress("${manifest.slug}", 8453);

const {hook: identity} = await describePool(client, dynamicFeePoolKey(tokenA, tokenB, 60, hook));
identity.name; // "${manifest.name}"`;

  const forgeSample = `// 1. Fix the pool's parameters. Callable once, only before the pool exists.
${manifest.contract}.Config memory config = ${manifest.contract}.Config({
${(configure?.fields ?? []).map((field) => `    ${field.name}: /* ${field.type} */ 0`).join(",\n")}
});
hook.configure(key, config);

// 2. Initialize the pool. The hook rejects a pool it was never configured for.
manager.initialize(key, startingSqrtPriceX96);`;

  return h`
<section class="hook-hero">
  <div class="shell">
    <span class="card__family">${esc(manifest.family)}</span>
    <h1 style="margin-bottom:0.25em">${esc(manifest.name)}</h1>
    <p class="lede" style="color:var(--text-dim);font-size:1.1rem;max-width:64ch">${esc(manifest.summary)}</p>
    <div class="card__tags" style="margin-top:1rem">${manifest.tags.map((tag) => `<span class="tag">${esc(tag)}</span>`).join("")}</div>
    <div class="lifecycle">
      <canvas data-permissions="${esc(JSON.stringify(permissions ?? {}))}"></canvas>
      <div class="lifecycle__fallback">The Uniswap v4 callback pipeline, with this hook's callbacks lit. Needs WebGL; the same information is in the permissions panel below.</div>
    </div>
  </div>
</section>

<div class="shell layout">
  <article class="prose">
    <h2 style="margin-top:0">How it works</h2>
    ${prose(manifest.description)}

    <div class="callout callout--prior">
      <h3>Prior art</h3>
      <p>${esc(manifest.priorArt)}</p>
    </div>

    <div class="callout">
      <h3>Where this does not help</h3>
      <p>${esc(manifest.limitation)}</p>
    </div>

    ${configure && configure.fields.length > 0
      ? h`
    <h2>Parameters</h2>
    <p>
      Set once per pool, before the pool exists, and never again. Anyone may call <code>configure</code> for a pool key
      that has not been initialized; nobody may change it afterwards, because a mutable configuration would let a
      third party rewrite the terms under a pool's liquidity providers.
    </p>
    <table>
      <thead><tr><th>Field</th><th>Type</th></tr></thead>
      <tbody>${configure.fields
        .map((field) => h`<tr><td><code>${esc(field.name)}</code></td><td><code>${esc(field.type)}</code></td></tr>`)
        .join("")}</tbody>
    </table>`
      : ""}

    <h2>Use it</h2>
    <h3>From Solidity</h3>
    <pre><code>${esc(forgeSample)}</code></pre>
    <h3>From TypeScript</h3>
    <pre><code>${esc(sdkSample)}</code></pre>

    ${errors.length > 0
      ? h`
    <h2>Errors</h2>
    <table>
      <thead><tr><th>Error</th><th>Meaning</th></tr></thead>
      <tbody>${errors
        .map((error) => h`<tr><td><code>${esc(error.signature)}</code></td><td>${esc(error.notice)}</td></tr>`)
        .join("")}</tbody>
    </table>`
      : ""}

    <h2>Deployments</h2>
    <p>
      Mined so that the low fourteen bits of each address encode exactly the callbacks above, which is how Uniswap
      decides what to call. The address differs per chain because the pool manager is a constructor argument, so it is
      reproducible rather than identical: re-run the deploy script and you derive the same address.
    </p>
    <table>
      <thead><tr><th>Chain</th><th>Chain ID</th><th>Address</th></tr></thead>
      <tbody>${deployments
        .map(
          (deployment) => h`<tr>
          <td>${esc(chainName(deployment.chain))}</td>
          <td><code>${deployment.chainId}</code></td>
          <td>${copyable(deployment.address)}</td>
        </tr>`,
        )
        .join("")}</tbody>
    </table>
  </article>

  <aside class="side">
    <div class="panel">
      <h3>At a glance</h3>
      <dl class="kv">
        <dt>Contract</dt><dd><code>${esc(manifest.contract)}</code></dd>
        <dt>Version</dt><dd>${esc(manifest.version)}</dd>
        <dt>Dynamic fee</dt><dd>${manifest.properties.dynamicFee ? "yes" : "no"}</dd>
        <dt>Upgradeable</dt><dd>${manifest.properties.upgradeable ? "yes" : "no"}</dd>
        <dt>Custom swap data</dt><dd>${manifest.properties.requiresCustomSwapData ? "required" : "not needed"}</dd>
        <dt>Swap access</dt><dd>${esc(manifest.properties.swapAccess)}</dd>
      </dl>
    </div>
    <div class="panel">
      <h3>Callbacks</h3>
      ${flagGrid(permissions)}
    </div>
    ${primary
      ? h`<div class="panel">
      <h3>Manifest</h3>
      <p style="font-size:0.85rem;color:var(--text-dim);margin-bottom:0.6rem">
        The same data this page is generated from, as JSON.
      </p>
      <p style="margin:0"><a href="/schema/hooks/${esc(manifest.slug)}.json">${esc(manifest.slug)}.json</a></p>
    </div>`
      : ""}
    <div class="panel">
      <h3>Source</h3>
      <p style="margin:0"><a href="${SITE.repo}/blob/main/${esc(manifest.source)}" rel="noopener">${esc(manifest.source.split("/").pop())}</a></p>
    </div>
  </aside>
</div>`;
}
