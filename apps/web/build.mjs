#!/usr/bin/env node
/**
 * Generates hookforge.dev.
 *
 * Every page is static HTML rendered from the hook registry, which is itself generated from the Solidity. Vite has
 * already bundled the client modules into hashed assets by the time this runs; this script reads Vite's manifest so
 * each page points at the right files, then writes the pages, the machine-readable endpoints and the SEO artifacts.
 *
 * Nothing here is hand-maintained. Adding a hook to the contracts and regenerating the registry adds its page, its
 * card, its manifest, its sitemap entry, its feed item, its social card and its llms.txt line.
 */
import {createRequire} from "node:module";
import {cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

import {SITE} from "./lib/layout.mjs";
import {homePage} from "./lib/pages/home.mjs";
import {cataloguePage} from "./lib/pages/catalogue.mjs";
import {hookPage} from "./lib/pages/hook.mjs";
import {chainsPage} from "./lib/pages/chains.mjs";
import {startHere, sdkDoc, mcpDoc, metadataDoc, deployDoc, agentsDoc} from "./lib/pages/docs.mjs";
import {hookCard, siteCard} from "./lib/og.mjs";

const require = createRequire(import.meta.url);
const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, "dist");
const REGISTRY = join(HERE, "..", "..", "packages", "registry");

/** Hooks in the catalogue that do not have a contract yet, so the roadmap is visible and honestly labelled. */
const PLANNED = JSON.parse(readFileSync(join(HERE, "lib", "planned.json"), "utf8"));

function write(path, contents) {
  const full = join(DIST, path);
  mkdirSync(dirname(full), {recursive: true});
  writeFileSync(full, contents);
  return full;
}

/** Reads the asset paths Vite produced, so pages reference hashed filenames that can be cached forever. */
function readAssets() {
  const manifestPath = join(DIST, ".vite", "manifest.json");
  if (!existsSync(manifestPath)) {
    throw new Error("Vite manifest missing. Run `vite build` before `node build.mjs` (npm run build does both).");
  }

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const entry = Object.values(manifest).find((chunk) => chunk.isEntry);
  if (!entry) throw new Error("No entry chunk in the Vite manifest.");

  return {
    js: [`/${entry.file}`],
    css: (entry.css ?? []).map((file) => `/${file}`),
  };
}

/** Every shipped hook's full manifest, ordered so the newest work leads the catalogue. */
function readHooks() {
  const dir = join(REGISTRY, "hooks");
  return readdirSync(dir)
    .filter((file) => file.endsWith(".json"))
    .map((file) => JSON.parse(readFileSync(join(dir, file), "utf8")))
    .sort((a, b) => a.family.localeCompare(b.family) || a.name.localeCompare(b.name));
}

/** Counts the assertions behind the catalogue, read from the Foundry and Node suites rather than typed in by hand. */
function countTests() {
  const contracts = join(HERE, "..", "..", "contracts", "test");
  const packages = [join(HERE, "..", "..", "packages", "sdk", "test"), join(HERE, "..", "..", "packages", "mcp", "test")];

  let total = 0;
  const walk = (dir, pattern) => {
    if (!existsSync(dir)) return;
    for (const file of readdirSync(dir, {withFileTypes: true})) {
      const full = join(dir, file.name);
      if (file.isDirectory()) walk(full, pattern);
      else if (file.isFile()) total += (readFileSync(full, "utf8").match(pattern) ?? []).length;
    }
  };
  walk(contracts, /function\s+(test|testFuzz|invariant)[A-Za-z0-9_]*\s*\(/g);
  for (const dir of packages) walk(dir, /^\s*test\(/gm);
  return total;
}

const assets = readAssets();
const hooks = readHooks();
const chains = JSON.parse(readFileSync(join(REGISTRY, "chains.json"), "utf8")).chains;
const index = JSON.parse(readFileSync(join(REGISTRY, "index.json"), "utf8"));
const testCount = countTests();
const today = new Date().toISOString().slice(0, 10);

/* ---------------------------------------------------------------- pages */

const pages = [
  ["index.html", homePage({hooks, planned: PLANNED, chains, assets, testCount}), "/", 1.0],
  ["hooks/index.html", cataloguePage({hooks, planned: PLANNED, assets}), "/hooks/", 0.9],
  ["chains/index.html", chainsPage({chains, hooks, assets}), "/chains/", 0.7],
  ["docs/index.html", startHere({assets, hooks}), "/docs/", 0.8],
  ["docs/sdk/index.html", sdkDoc({assets}), "/docs/sdk/", 0.7],
  ["docs/mcp/index.html", mcpDoc({assets}), "/docs/mcp/", 0.7],
  ["docs/metadata/index.html", metadataDoc({assets}), "/docs/metadata/", 0.7],
  ["docs/deploy/index.html", deployDoc({assets}), "/docs/deploy/", 0.7],
  ["docs/agents/index.html", agentsDoc({assets, hooks}), "/docs/agents/", 0.8],
];

for (const hook of hooks) {
  pages.push([`hooks/${hook.slug}/index.html`, hookPage(hook, {assets, chains}), `/hooks/${hook.slug}/`, 0.8]);
}

for (const [path, html] of pages) write(path, html);

/* ------------------------------------------------------- machine readable */

// The manifests are served at exactly the URL every deployed hook returns from `specURI()`, so the on-chain pointer
// resolves. This is the one path on the site that a contract depends on.
for (const hook of hooks) {
  write(`schema/hooks/${hook.slug}.json`, `${JSON.stringify(hook, null, 2)}\n`);
}
cpSync(join(REGISTRY, "schema"), join(DIST, "schema"), {recursive: true, force: true});
write("api/hooks.json", `${JSON.stringify(index, null, 2)}\n`);
write("api/chains.json", `${JSON.stringify({chains}, null, 2)}\n`);
write("registry.json", `${JSON.stringify(index, null, 2)}\n`);

/* ---------------------------------------------------------------- social */

write("og/default.png", siteCard({
  eyebrow: "Uniswap v4",
  title: "Hooks nobody built yet",
  summary: `${hooks.length} production Uniswap v4 hooks with prior art, limitations and tests stated in the source.`,
}));
write("og/hooks.png", siteCard({
  eyebrow: "Catalogue",
  title: `${hooks.length} shipped hooks`,
  summary: "Searchable by the problem: MEV and order flow, curves, risk, LP economics, launches, time, agents.",
  footer: "hookforge.dev/hooks",
}));
write("og/chains.png", siteCard({
  eyebrow: "Deployment",
  title: "Chains and addresses",
  summary: "PoolManager addresses and deterministic hook addresses for Base, Arbitrum, Unichain and Robinhood Chain.",
  footer: "hookforge.dev/chains",
}));
write("og/docs.png", siteCard({
  eyebrow: "Documentation",
  title: "Build with HookForge",
  summary: "The SDK, the MCP server, on-chain hook metadata, and how to deploy a hook to a mined address.",
  footer: "hookforge.dev/docs",
}));
for (const hook of hooks) write(`og/hooks/${hook.slug}.png`, hookCard(hook));

/* ------------------------------------------------------------------- SEO */

write(
  "sitemap.xml",
  `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${pages
  .map(
    ([, , path, priority]) =>
      `  <url><loc>${SITE.url}${path}</loc><lastmod>${today}</lastmod><priority>${priority.toFixed(1)}</priority></url>`,
  )
  .join("\n")}
</urlset>
`,
);

write(
  "robots.txt",
  `# hookforge.dev
# The catalogue is meant to be read by machines as well as people. Nothing here is rate limited or gated,
# and the JSON endpoints below are cheaper for you than parsing the HTML.
User-agent: *
Allow: /

Sitemap: ${SITE.url}/sitemap.xml

# Machine-readable entry points
# ${SITE.url}/llms.txt          the catalogue as plain text
# ${SITE.url}/llms-full.txt     every hook in full
# ${SITE.url}/api/hooks.json    the registry
# ${SITE.url}/api/chains.json   the address book
`,
);

const llms = `# HookForge

> ${SITE.description}

${hooks.length} hooks are shipped: contract, tests, deploy script, manifest and documentation, MIT licensed, no admin
keys. Source: ${SITE.repo}

Every hook also describes itself on-chain through IHookMetadata (hookName, hookVersion, specURI, hookTags), so a hook
address can be identified in one eth_call with no registry in the loop.

## Hooks

${hooks.map((hook) => `- [${hook.name}](${SITE.url}/hooks/${hook.slug}/): ${hook.summary}`).join("\n")}

## Documentation

- [Start here](${SITE.url}/docs/): what a v4 hook is, how to run and use these.
- [TypeScript SDK](${SITE.url}/docs/sdk/): catalogue, address book, pool keys, permission decoding.
- [MCP server](${SITE.url}/docs/mcp/): six tools for agents; npx -y @hookforge/mcp
- [On-chain metadata](${SITE.url}/docs/metadata/): the IHookMetadata interface.
- [Deploy a hook](${SITE.url}/docs/deploy/): mining a CREATE2 salt so the address encodes the permission flags.
- [For agents](${SITE.url}/docs/agents/): every machine-readable endpoint.

## Machine-readable

- ${SITE.url}/api/hooks.json
- ${SITE.url}/api/chains.json
- ${SITE.url}/schema/hooks/<slug>.json
- ${SITE.url}/llms-full.txt

## Important caveats

- These contracts are unaudited.
- A deployment whose status is "deterministic" is a mined CREATE2 address with no code at it yet. Never present one as live.
- Fee-overriding hooks require a pool initialized with the dynamic-fee flag and revert otherwise.
`;
write("llms.txt", llms);

write(
  "llms-full.txt",
  `${llms}\n---\n\n${hooks
    .map(
      (hook) => `# ${hook.name}

Slug: ${hook.slug}
Family: ${hook.family}
Contract: ${hook.contract}
Tags: ${hook.tags.join(", ")}
Page: ${SITE.url}/hooks/${hook.slug}/
Manifest: ${SITE.url}/schema/hooks/${hook.slug}.json
Source: ${SITE.repo}/blob/main/${hook.source}
Callbacks: ${Object.entries(hook.permissions ?? {}).filter(([, on]) => on).map(([name]) => name).join(", ") || "none"}
Parameters: ${(hook.configure?.fields ?? []).map((f) => `${f.name} (${f.type})`).join(", ") || "none"}

## Summary
${hook.summary}

## How it works
${hook.description}

## Prior art
${hook.priorArt || "Not stated."}

## Where it does not help
${hook.limitation || "Not stated."}
`,
    )
    .join("\n---\n\n")}`,
);

write(
  "feed.xml",
  `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
  <title>HookForge</title>
  <link>${SITE.url}</link>
  <description>${SITE.description}</description>
  <language>en</language>
  <atom:link href="${SITE.url}/feed.xml" rel="self" type="application/rss+xml"/>
${hooks
  .map(
    (hook) => `  <item>
    <title>${hook.name}</title>
    <link>${SITE.url}/hooks/${hook.slug}/</link>
    <guid isPermaLink="true">${SITE.url}/hooks/${hook.slug}/</guid>
    <description><![CDATA[${hook.summary}]]></description>
    <category>${hook.family}</category>
  </item>`,
  )
  .join("\n")}
</channel>
</rss>
`,
);

write(
  "favicon.svg",
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"><rect width="24" height="24" rx="5" fill="#07080b"/><path d="M5 19V8.5a3.5 3.5 0 0 1 7 0v7a3.5 3.5 0 0 0 7 0V5" stroke="#ff6a2b" stroke-width="2.4" stroke-linecap="round"/></svg>
`,
);

// Cloudflare Pages: long-lived caching for hashed assets, revalidation for HTML and the JSON endpoints.
write(
  "_headers",
  `/assets/*
  Cache-Control: public, max-age=31536000, immutable

/og/*
  Cache-Control: public, max-age=86400

/*.html
  Cache-Control: public, max-age=0, must-revalidate

/api/*
  Cache-Control: public, max-age=300
  Access-Control-Allow-Origin: *

/schema/*
  Cache-Control: public, max-age=300
  Access-Control-Allow-Origin: *

/llms.txt
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *

/llms-full.txt
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *

/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
`,
);

console.log(`built ${pages.length} pages, ${hooks.length} manifests, ${hooks.length + 4} social cards, ${testCount} tests counted`);
