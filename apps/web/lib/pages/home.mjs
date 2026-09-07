import {esc, h} from "../html.mjs";
import {page, SITE} from "../layout.mjs";
import {hookCard} from "./catalogue.mjs";

export function homePage({hooks, planned, chains, assets, testCount}) {
  const featured = hooks.slice(0, 6);

  const jsonLd = [
    {
      "@context": "https://schema.org",
      "@type": "WebSite",
      name: SITE.name,
      url: SITE.url,
      description: SITE.description,
      potentialAction: {
        "@type": "SearchAction",
        target: {"@type": "EntryPoint", urlTemplate: `${SITE.url}/hooks/?q={search_term_string}`},
        "query-input": "required name=search_term_string",
      },
    },
    {
      "@context": "https://schema.org",
      "@type": "SoftwareSourceCode",
      name: "HookForge",
      description: SITE.description,
      codeRepository: SITE.repo,
      programmingLanguage: ["Solidity", "TypeScript"],
      license: "https://www.apache.org/licenses/LICENSE-2.0",
      runtimePlatform: "Ethereum Virtual Machine",
    },
  ];

  const body = h`
<section class="hero">
  <canvas class="hero__canvas" data-hero aria-hidden="true"></canvas>
  <div class="shell hero__inner">
    <div class="prose">
      <p class="eyebrow">Uniswap v4 hooks</p>
      <h1>Mechanisms nobody built yet, written properly.</h1>
      <p class="lede">
        Uniswap v4 turned the AMM into a platform, and most of what has been built on it re-implements something that
        already worked: limit orders, TWAMM, a KYC gate, another dynamic fee. HookForge is a catalogue of what is
        missing. Every hook is checked against the roughly 140 published hooks and hackathon submissions before it is
        written, states its prior art and its limitations in its own source, and ships with tests against a real
        <code>PoolManager</code>, a deploy script, a TypeScript client and a page here.
      </p>
      <div class="cta-row">
        <a class="btn btn--primary" href="/hooks/">Browse ${hooks.length} shipped hooks</a>
        <a class="btn" href="/docs/">Read the docs</a>
        <a class="btn" href="${esc(SITE.repo)}" rel="noopener">Source on GitHub</a>
      </div>
    </div>

  </div>
</section>

<section class="shell">
  <dl class="stats">
    <div class="stat"><dt>Hooks shipped</dt><dd>${hooks.length}</dd></div>
    <div class="stat"><dt>In the catalogue</dt><dd>${hooks.length + planned.length}</dd></div>
    <div class="stat"><dt>Tests passing</dt><dd>${testCount}</dd></div>
    <div class="stat"><dt>Chains</dt><dd>${chains.length}</dd></div>
    <div class="stat"><dt>Admin keys</dt><dd>0</dd></div>
  </dl>
</section>

<section class="shell">
  <div class="prose">
    <h2>What makes these different</h2>
  </div>
  <ul class="grid">
    <li class="card">
      <h3 class="card__name">They answer for themselves</h3>
      <p class="card__summary">
        A hook is just an address in a <code>PoolKey</code>, and nothing about that address tells an indexer, a wallet or
        an agent what the pool does. Every HookForge hook implements <code>IHookMetadata</code>: ask it its name, its
        version, its tags and the URI of its manifest, in one <code>eth_call</code>, with no registry in the loop.
      </p>
    </li>
    <li class="card">
      <h3 class="card__name">The docs are generated from the contract</h3>
      <p class="card__summary">
        Every page here is built from the Solidity: the prose is its NatSpec, the parameters are its <code>configure</code>
        ABI, the callbacks are the flags it declares, the tags are what <code>hookTags()</code> returns. Documentation
        drift is not managed, it is impossible.
      </p>
    </li>
    <li class="card">
      <h3 class="card__name">Prior art is part of the contract</h3>
      <p class="card__summary">
        Each hook names what already exists and what is actually new about it, in the source, where it cannot be quietly
        dropped from a marketing page. If a mechanism has been built before, this catalogue says so.
      </p>
    </li>
    <li class="card">
      <h3 class="card__name">Limitations are stated, not buried</h3>
      <p class="card__summary">
        Every hook has a section saying where it does not help. A fee that prices staleness does nothing for a busy
        pair; a priority-fee tax is inert on a chain with no priority auction. That belongs on the page, not in a
        post-mortem.
      </p>
    </li>
    <li class="card">
      <h3 class="card__name">Agents are a first-class reader</h3>
      <p class="card__summary">
        The catalogue ships as an <a href="/docs/mcp/">MCP server</a>, a <a href="/llms.txt">llms.txt</a>, and JSON at
        stable URLs. A coding agent can search by problem, read a hook's parameters, and decode what any hook address
        will do, without scraping this page.
      </p>
    </li>
    <li class="card">
      <h3 class="card__name">No admin keys</h3>
      <p class="card__summary">
        Nothing in this catalogue has an owner, a pause switch or an upgrade path. Parameters are fixed before a pool
        exists and cannot be changed under the liquidity that trusted them.
      </p>
    </li>
  </ul>
</section>

<section class="shell">
  <div class="prose">
    <h2>Recently shipped</h2>
    <p>Hover a card to see which of the fourteen callbacks it claims.</p>
  </div>
  <ul class="grid">
    ${featured.map(hookCard).join("\n    ")}
  </ul>
  <p style="margin-top:1.5rem"><a class="btn" href="/hooks/">All ${hooks.length} hooks</a></p>
</section>

<section class="shell">
  <div class="prose">
    <h2>Use one in five minutes</h2>
    <pre><code>npm i @hookforge/sdk

import {getHook, hookAddress, poolKeyFor} from "@hookforge/sdk";

// Which hook solves "my pool is arbitraged after every quiet period"?
const hook = getHook("arb-tax-decay");
const key  = poolKeyFor({
  hook: hookAddress("arb-tax-decay", 8453),   // Base
  currencyA: USDC, currencyB: WETH,
  tickSpacing: 60, dynamicFee: true,
});</code></pre>
    <p>
      Or point a coding agent at the catalogue directly:
    </p>
    <pre><code>{
  "mcpServers": {
    "hookforge": {"command": "npx", "args": ["-y", "@hookforge/mcp"]}
  }
}</code></pre>
  </div>
</section>`;

  return page({
    title: "HookForge: production Uniswap v4 hooks that did not exist yet",
    description: SITE.description,
    path: "/",
    assets,
    body,
    jsonLd,
    ogImage: `${SITE.url}/og/default.png`,
  });
}
