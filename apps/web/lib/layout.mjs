import {esc, h} from "./html.mjs";

export const SITE = {
  name: "HookForge",
  url: "https://hookforge.dev",
  tagline: "50 production Uniswap v4 hooks that do not exist yet",
  repo: "https://github.com/nirholas/hookforge",
  description:
    "A catalogue of Uniswap v4 hooks nobody has built: novel AMM mechanisms in audited-shape Solidity, each with its prior art and its limitations stated, a TypeScript SDK, an MCP server for agents, and deployments on Base, Arbitrum, Unichain and Robinhood Chain.",
};

const NAV = [
  {href: "/hooks/", label: "Hooks"},
  {href: "/docs/", label: "Docs"},
  {href: "/docs/sdk/", label: "SDK"},
  {href: "/docs/mcp/", label: "MCP"},
  {href: SITE.repo, label: "GitHub", external: true},
];

const MARK = `<svg class="brand__mark" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 20V8a4 4 0 0 1 8 0v8a4 4 0 0 0 8 0V4" stroke="#ff6a2b" stroke-width="2.4" stroke-linecap="round"/></svg>`;

/**
 * The page shell.
 *
 * Every generated page passes through here, so the head is consistent: one canonical URL, one description, Open Graph
 * and Twitter cards, JSON-LD, and the hashed asset paths Vite produced for this build.
 */
export function page({title, description, path, assets, body, jsonLd = [], noindex = false, ogImage}) {
  const canonical = `${SITE.url}${path}`;
  const image = ogImage ?? `${SITE.url}/og/default.png`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${esc(canonical)}">
${noindex ? '<meta name="robots" content="noindex">' : '<meta name="robots" content="index, follow, max-image-preview:large">'}

<meta property="og:type" content="website">
<meta property="og:site_name" content="${esc(SITE.name)}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(canonical)}">
<meta property="og:image" content="${esc(image)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${esc(image)}">

<meta name="theme-color" content="#07080b">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="alternate" type="application/rss+xml" title="HookForge" href="/feed.xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
${assets.css.map((href) => `<link rel="stylesheet" href="${esc(href)}">`).join("\n")}
${jsonLd.map((block) => `<script type="application/ld+json">${JSON.stringify(block)}</script>`).join("\n")}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="masthead">
  <div class="shell masthead__inner">
    <a class="brand" href="/">${MARK}<span>HookForge</span></a>
    <nav aria-label="Primary">
      ${NAV.map((item) =>
        h`<a href="${esc(item.href)}"${item.external ? ' rel="noopener"' : ""}${path === item.href ? ' aria-current="page"' : ""}>${esc(item.label)}</a>`,
      ).join("\n      ")}
    </nav>
  </div>
</header>
<main id="main">
${body}
</main>
<footer class="foot">
  <div class="shell">
    <div class="foot__cols">
      <div>
        <h4>Catalogue</h4>
        <ul>
          <li><a href="/hooks/">All hooks</a></li>
          <li><a href="/api/hooks.json">Registry JSON</a></li>
          <li><a href="/llms.txt">llms.txt</a></li>
        </ul>
      </div>
      <div>
        <h4>Build</h4>
        <ul>
          <li><a href="/docs/">Start here</a></li>
          <li><a href="/docs/sdk/">TypeScript SDK</a></li>
          <li><a href="/docs/mcp/">MCP server</a></li>
          <li><a href="/docs/deploy/">Deploy a hook</a></li>
        </ul>
      </div>
      <div>
        <h4>Source</h4>
        <ul>
          <li><a href="${SITE.repo}" rel="noopener">GitHub</a></li>
          <li><a href="${SITE.repo}/issues" rel="noopener">Propose a hook</a></li>
          <li><a href="https://github.com/Uniswap/hooklist" rel="noopener">Uniswap hooklist</a></li>
        </ul>
      </div>
    </div>
    <p class="foot__legal">
      MIT licensed. Not affiliated with Uniswap Labs. These contracts are unaudited: read the limitation on every hook
      page before putting money behind one.
    </p>
  </div>
</footer>
${assets.js.map((src) => `<script type="module" src="${esc(src)}"></script>`).join("\n")}
</body>
</html>
`;
}
