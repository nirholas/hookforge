import {esc, h, prose, copyable} from "../html.mjs";
import {page, SITE} from "../layout.mjs";

/** The fourteen permission bits in address order: the same order v4 packs them into the low bits of a hook address. */
const BITS = [
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

/** Solidity type to a readable note, so a parameter table explains units rather than restating the type. */
function fieldNote(name) {
  if (/fee|surcharge/i.test(name)) return "hundredths of a bip (3000 = 0.30%)";
  if (/bps/i.test(name)) return "basis points (10000 = 100%)";
  if (/seconds|halfLife|ramp|window|cooldown/i.test(name)) return "seconds";
  if (/timestamp|unlock/i.test(name)) return "unix seconds";
  if (/wei/i.test(name)) return "wei per gas";
  if (/tick/i.test(name)) return "tick";
  return "";
}

function permissionList(permissions) {
  if (!permissions) return "";
  return `<ul class="flags">${BITS.map(
    (bit) => `<li class="flag${permissions[bit] ? " flag--on" : ""}">${esc(bit)}</li>`,
  ).join("")}</ul>`;
}

function addressTable(deployments) {
  if (!deployments?.length) {
    return `<p class="muted">No addresses published yet. The deploy script mines a deterministic address per chain, so
      the address a hook will occupy is known before it is deployed; this hook has not had that step run.</p>`;
  }

  const deterministic = deployments.some((d) => d.status === "deterministic");
  return h`
    <table class="addresses">
      <thead><tr><th>Chain</th><th>Chain ID</th><th>Address</th></tr></thead>
      <tbody>
        ${deployments
          .map(
            (d) =>
              `<tr><td>${esc(d.chain)}</td><td><code>${esc(d.chainId)}</code></td><td>${copyable(d.address)}</td></tr>`,
          )
          .join("\n        ")}
      </tbody>
    </table>
    ${
      deterministic
        ? `<p class="muted"><strong>These addresses are deterministic, not live.</strong> They are the CREATE2 addresses
           the deploy script mines so that the low fourteen bits encode this hook's permissions. Until the deploy runs
           on a chain, there is no code at them. Check before you send anything anywhere.</p>`
        : ""
    }`;
}

function configureSnippet(hook) {
  if (!hook.configure) return "";
  const fields = hook.configure.fields ?? [];
  const literal = fields.map((f) => `        ${f.name}: /* ${f.type} */ 0`).join(",\n");

  return h`
<h2 id="configure">Configuring a pool</h2>
<p>
  Uniswap v4 removed <code>hookData</code> from <code>initialize</code>, so a hook that needs per-pool parameters has to
  receive them out of band. ${esc(hook.name)} takes them through <code>configure</code>, which anyone may call for a pool
  key whose pool does not exist yet, and which nobody may call afterwards. The parameters are part of what the pool
  <em>is</em>, so they are fixed for its lifetime.
</p>
<pre><code>// 1. Fix the terms, before the pool exists.
hook.configure(
    key,
    ${esc(hook.contract)}.Config({
${literal || "        // no parameters"}
    })
);

// 2. Initialize the pool. The hook rejects a pool it was never configured for.
poolManager.initialize(key, startingSqrtPriceX96);</code></pre>
${
  fields.length
    ? h`<table class="addresses">
  <thead><tr><th>Parameter</th><th>Type</th><th>Units</th></tr></thead>
  <tbody>
    ${fields
      .map(
        (f) =>
          `<tr><td><code>${esc(f.name)}</code></td><td><code>${esc(f.type)}</code></td><td>${esc(fieldNote(f.name))}</td></tr>`,
      )
      .join("\n    ")}
  </tbody>
</table>`
    : ""
}`;
}

function errorTable(errors) {
  const own = (errors ?? []).filter((e) => !["HookNotImplemented()", "NotPoolManager()", "InvalidPool()"].includes(e.signature));
  if (!own.length) return "";

  return h`
<h2 id="errors">What it reverts with</h2>
<table class="addresses">
  <thead><tr><th>Error</th><th>Meaning</th></tr></thead>
  <tbody>
    ${own
      .map((e) => `<tr><td><code>${esc(e.signature)}</code></td><td>${esc(e.notice ?? "")}</td></tr>`)
      .join("\n    ")}
  </tbody>
</table>`;
}

export function hookPage(hook, {assets, chains}) {
  const title = `${hook.name}: ${hook.summary.replace(/\.$/, "")}`;
  const claimed = BITS.filter((bit) => hook.permissions?.[bit]);

  const jsonLd = [
    {
      "@context": "https://schema.org",
      "@type": "TechArticle",
      headline: `${hook.name} (Uniswap v4 hook)`,
      description: hook.summary,
      url: `${SITE.url}/hooks/${hook.slug}/`,
      about: {"@type": "SoftwareSourceCode", name: hook.contract, programmingLanguage: "Solidity", codeRepository: SITE.repo},
      keywords: hook.tags.join(", "),
      isPartOf: {"@type": "WebSite", name: SITE.name, url: SITE.url},
      license: "https://www.apache.org/licenses/LICENSE-2.0",
    },
    {
      "@context": "https://schema.org",
      "@type": "BreadcrumbList",
      itemListElement: [
        {"@type": "ListItem", position: 1, name: "Hooks", item: `${SITE.url}/hooks/`},
        {"@type": "ListItem", position: 2, name: hook.name, item: `${SITE.url}/hooks/${hook.slug}/`},
      ],
    },
  ];

  const body = h`
<article class="shell layout">
  <div class="prose">
    <p class="eyebrow"><a href="/hooks/">Hooks</a> / ${esc(hook.family)}</p>
    <h1>${esc(hook.name)}</h1>
    <p class="hook-hero">${esc(hook.summary)}</p>

    <div class="lifecycle">
      <canvas data-permissions="${esc(JSON.stringify(hook.permissions ?? {}))}" aria-hidden="true"></canvas>
      <p class="lifecycle__fallback">
        ${esc(hook.name)} implements ${claimed.length} of the fourteen Uniswap v4 callbacks:
        ${claimed.map((bit) => `<code>${esc(bit)}</code>`).join(", ") || "none"}.
      </p>
    </div>

    <h2 id="how-it-works">How it works</h2>
    ${prose(hook.description)}

    ${
      hook.priorArt
        ? h`<div class="callout callout--prior">
            <h3>Prior art</h3>
            ${prose(hook.priorArt, 4)}
          </div>`
        : ""
    }

    ${
      hook.limitation
        ? h`<div class="callout callout--warn">
            <h3>Where it does not help</h3>
            ${prose(hook.limitation, 4)}
          </div>`
        : ""
    }

    ${configureSnippet(hook)}

    <h2 id="typescript">From TypeScript</h2>
    <p>
      The SDK ships the catalogue, the address book and the pool-key helpers, so a client never hardcodes an address or
      recomputes a pool id by hand.
    </p>
    <pre><code>npm i @hookforge/sdk

import {getHook, hookAddress, poolKeyFor, poolId} from "@hookforge/sdk";

const hook = getHook("${esc(hook.slug)}");
const address = hookAddress("${esc(hook.slug)}", ${esc(chains[0]?.chainId ?? 8453)});
const key = poolKeyFor({hook: address, currencyA: USDC, currencyB: WETH, tickSpacing: 60${
    hook.properties?.dynamicFee ? ", dynamicFee: true" : ""
  }});
console.log(poolId(key));</code></pre>

    ${errorTable(hook.errors)}

    <h2 id="addresses">Addresses</h2>
    ${addressTable(hook.deployments)}

    <h2 id="source">Source and verification</h2>
    <p>
      The contract is <a href="${esc(SITE.repo)}/blob/main/${esc(hook.source)}" rel="noopener"><code>${esc(hook.source)}</code></a>,
      and everything on this page is generated from it: the prose is its NatSpec, the parameters are its
      <code>configure</code> ABI, the callbacks above are the flags it declares, and the tags are the strings its own
      <code>hookTags()</code> returns. A hook cannot be documented here as something it is not.
    </p>
    <p>
      Ask the deployed contract what it is and it answers directly, with no registry in the loop:
    </p>
    <pre><code>cast call $HOOK "hookName()(string)"    # ${esc(hook.name)}
cast call $HOOK "specURI()(string)"     # ${SITE.url}/schema/hooks/${esc(hook.slug)}.json
cast call $HOOK "hookTags()(string[])"  # ${esc(hook.tags.join(", "))}</code></pre>
  </div>

  <aside class="side">
    <div class="panel">
      <h4>At a glance</h4>
      <dl class="kv">
        <dt>Family</dt><dd>${esc(hook.family)}</dd>
        <dt>Contract</dt><dd><code>${esc(hook.contract)}</code></dd>
        <dt>Version</dt><dd>${esc(hook.version)}</dd>
        <dt>Fee</dt><dd>${hook.properties?.dynamicFee ? "dynamic" : "static"}</dd>
        <dt>Custom swap data</dt><dd>${hook.properties?.requiresCustomSwapData ? "required" : "none"}</dd>
        <dt>Swap access</dt><dd>${esc(hook.properties?.swapAccess ?? "none")}</dd>
        <dt>Upgradeable</dt><dd>${hook.properties?.upgradeable ? "yes" : "no"}</dd>
      </dl>
    </div>

    <div class="panel">
      <h4>Callbacks claimed (${claimed.length}/14)</h4>
      ${permissionList(hook.permissions)}
      <p class="muted" style="margin:.7rem 0 0;font-size:.82rem">
        ${
          hook.permissionsSource === "address"
            ? "Read from the low fourteen bits of the deployed address, which is the only place v4 itself looks."
            : "Read from the hook's own getHookPermissions() declaration; the deploy script mines an address to match."
        }
      </p>
    </div>

    ${
      hook.repo
        ? `<div class="panel">
      <h4>Its own home</h4>
      <p style="margin:0 0 .6rem;font-size:.9rem;color:var(--text-dim)">
        Every hook here is also published on its own, with its own repository, documentation and site.
      </p>
      <ul>
        <li><a href="${esc(hook.site)}" rel="noopener">${esc((hook.site ?? "").replace("https://", ""))}</a></li>
        <li><a href="${esc(hook.repo)}" rel="noopener">Repository</a></li>
      </ul>
    </div>`
        : ""
    }

    <div class="panel">
      <h4>Machine readable</h4>
      <ul>
        <li><a href="/schema/hooks/${esc(hook.slug)}.json">Manifest JSON</a></li>
        <li><a href="/api/hooks.json">Full registry</a></li>
        <li><a href="/docs/mcp/">MCP server</a></li>
      </ul>
    </div>

    <div class="panel">
      <h4>Tags</h4>
      <ul class="flags">${hook.tags.map((tag) => `<li class="tag">${esc(tag)}</li>`).join("")}</ul>
    </div>
  </aside>
</article>`;

  return page({
    title: `${hook.name} | HookForge`,
    description: hook.summary.slice(0, 300),
    path: `/hooks/${hook.slug}/`,
    assets,
    body,
    jsonLd,
    ogImage: `${SITE.url}/og/hooks/${hook.slug}.png`,
  });
}
