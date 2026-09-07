/**
 * Emits a standalone hook's own website into its repository.
 *
 * A spun-out repository has to be able to build and publish its site with nothing installed, so what lands in `web/`
 * is a build script with no dependencies, a stylesheet, and one ES module that pulls three.js from a pinned CDN
 * through an import map. The social card is rasterised here, where a rasteriser is available, and committed as a
 * static asset.
 *
 * The page itself is server-rendered HTML. The 3D scene is decoration over content that is already complete: with
 * JavaScript disabled, or WebGL unavailable, the page still says everything it has to say.
 */
import {mkdirSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";

import {claimedFlags, errorTable, flagMask, paragraphs, parameterTable} from "./templates.mjs";
import {hookCard} from "../../apps/web/lib/og.mjs";

const THREE_VERSION = "0.170.0";
const THREE_CDN = `https://cdn.jsdelivr.net/npm/three@${THREE_VERSION}/build/three.module.js`;

function write(root, path, contents) {
  const full = join(root, path);
  mkdirSync(dirname(full), {recursive: true});
  writeFileSync(full, contents);
}

const SCENE = `/**
 * The Uniswap v4 callback pipeline, with this hook's callbacks lit.
 *
 * A swap runs left to right through the gates the protocol offers. The ones this hook implements glow and pulse as
 * the swap passes; the ones it does not are dark and inert. That is the whole contract between a hook and the
 * protocol, and reading it off a picture is faster than reading it off fourteen booleans.
 *
 * The scene is decoration over content that is already complete. Without WebGL, or with JavaScript off, the page
 * reads exactly the same.
 */
import {
  AdditiveBlending, CanvasTexture, Color, Group, Mesh, MeshBasicMaterial, OrthographicCamera, PlaneGeometry,
  Scene, SphereGeometry, Sprite, SpriteMaterial, TorusGeometry, WebGLRenderer,
} from "three";

const STAGES = [
  ["beforeInitialize", "beforeInitialize"],
  ["afterInitialize", "afterInitialize"],
  ["beforeAddLiquidity", "beforeAddLiq"],
  ["afterAddLiquidity", "afterAddLiq"],
  ["beforeSwap", "beforeSwap"],
  ["afterSwap", "afterSwap"],
  ["beforeRemoveLiquidity", "beforeRemoveLiq"],
  ["afterRemoveLiquidity", "afterRemoveLiq"],
  ["beforeDonate", "beforeDonate"],
  ["afterDonate", "afterDonate"],
];

const ON = new Color("#ff6a2b");
const OFF = new Color("#232a35");

function labelSprite(text, active) {
  const canvas = document.createElement("canvas");
  const scale = 3;
  canvas.width = 300 * scale;
  canvas.height = 56 * scale;

  const ctx = canvas.getContext("2d");
  ctx.scale(scale, scale);
  ctx.font = "500 19px ui-monospace, SFMono-Regular, Menlo, monospace";
  ctx.fillStyle = active ? "#e8eaef" : "#5a6373";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, 150, 28);

  const sprite = new Sprite(new SpriteMaterial({map: new CanvasTexture(canvas), transparent: true, depthTest: false}));
  sprite.scale.set(2.6, 0.49, 1);
  return sprite;
}

const canvas = document.querySelector("canvas[data-permissions]");
if (canvas) mount(canvas, JSON.parse(canvas.dataset.permissions));

function mount(canvas, permissions) {
  let renderer;
  try {
    renderer = new WebGLRenderer({canvas, antialias: true, alpha: true, powerPreference: "low-power"});
  } catch {
    return;
  }

  const fallback = canvas.parentElement?.querySelector(".scene__fallback");
  if (fallback) fallback.remove();

  const scene = new Scene();
  const camera = new OrthographicCamera(-1, 1, 1, -1, 0.1, 100);
  camera.position.z = 10;

  const root = new Group();
  scene.add(root);

  const spacing = 1.6;
  const span = (STAGES.length - 1) * spacing;
  const gates = [];

  root.add(new Mesh(new PlaneGeometry(span + spacing, 0.012), new MeshBasicMaterial({color: OFF, transparent: true, opacity: 0.7})));

  STAGES.forEach(([key, label], index) => {
    const active = Boolean(permissions[key]);
    const x = index * spacing - span / 2;

    const ring = new Mesh(
      new TorusGeometry(0.34, active ? 0.035 : 0.018, 10, 56),
      new MeshBasicMaterial({color: active ? ON : OFF, transparent: true, opacity: active ? 0.95 : 0.55}),
    );
    ring.position.set(x, 0, 0);
    root.add(ring);

    let glow = null;
    if (active) {
      glow = new Mesh(
        new TorusGeometry(0.34, 0.13, 10, 56),
        new MeshBasicMaterial({color: ON, transparent: true, opacity: 0.1, blending: AdditiveBlending}),
      );
      glow.position.copy(ring.position);
      root.add(glow);
    }

    const sprite = labelSprite(label, active);
    sprite.position.set(x, -0.78, 0);
    root.add(sprite);

    gates.push({x, active, ring, glow});
  });

  const swap = new Mesh(new SphereGeometry(0.085, 16, 16), new MeshBasicMaterial({color: new Color("#4ecdc4")}));
  root.add(swap);

  function resize() {
    const {clientWidth, clientHeight} = canvas;
    if (clientWidth === 0 || clientHeight === 0) return;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(clientWidth, clientHeight, false);

    const worldWidth = span + spacing * 1.4;
    const halfHeight = (worldWidth * clientHeight) / clientWidth / 2;
    camera.left = -worldWidth / 2;
    camera.right = worldWidth / 2;
    camera.top = halfHeight;
    camera.bottom = -halfHeight;
    camera.updateProjectionMatrix();
  }

  const startX = -span / 2 - spacing * 0.7;
  const endX = span / 2 + spacing * 0.7;

  function step(elapsed) {
    const x = startX + (endX - startX) * ((elapsed % 7) / 7);
    swap.position.set(x, 0, 0.2);
    for (const gate of gates) {
      if (!gate.active) continue;
      const excitement = Math.max(0, 1 - Math.abs(x - gate.x) / 0.75);
      gate.ring.material.opacity = 0.72 + excitement * 0.28;
      gate.ring.scale.setScalar(1 + excitement * 0.16);
      if (gate.glow) gate.glow.material.opacity = 0.07 + excitement * 0.3;
    }
  }

  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  let elapsed = 0;
  let last = performance.now();
  let visible = true;

  resize();
  if (reduced) {
    const first = gates.find((gate) => gate.active);
    step(first ? ((first.x - startX) / (endX - startX)) * 7 : 0);
    renderer.render(scene, camera);
  } else {
    const frame = (now) => {
      requestAnimationFrame(frame);
      const delta = Math.min((now - last) / 1000, 0.05);
      last = now;
      if (!visible) return;
      elapsed += delta;
      step(elapsed);
      renderer.render(scene, camera);
    };
    requestAnimationFrame(frame);
  }

  window.addEventListener("resize", resize, {passive: true});
  new IntersectionObserver((entries) => {
    visible = entries.some((entry) => entry.isIntersecting);
  }).observe(canvas);
}

// Copy buttons, for the addresses and commands this page exists to hand people.
document.addEventListener("click", async (event) => {
  const button = event.target.closest(".copy");
  if (!button || !navigator.clipboard) return;
  const value = button.dataset.copy ?? button.previousElementSibling?.textContent ?? "";
  await navigator.clipboard.writeText(value);
  const previous = button.textContent;
  button.textContent = "copied";
  setTimeout(() => { button.textContent = previous; }, 1400);
});
`;

const CSS = `/* One hook, one page. Dark because the scene is lit and a light theme behind it reads wrong. */
:root {
  color-scheme: dark;
  --ink: #07080b; --ink-raised: #0d0f14; --ink-sunken: #050609;
  --line: #1b1f28; --line-bright: #2a303c;
  --text: #e8eaef; --text-dim: #9aa3b2; --text-faint: #868e9c;
  --forge: #ff6a2b; --forge-soft: #ff8a52; --forge-glow: rgba(255, 106, 43, 0.12);
  --radius: 10px; --radius-lg: 16px;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  --font: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Inter, Roboto, sans-serif;
}
*, *::before, *::after { box-sizing: border-box; }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation-duration: .01ms !important; transition-duration: .01ms !important; } }
body { margin: 0; background: var(--ink); color: var(--text); font-family: var(--font); font-size: 16px; line-height: 1.65; -webkit-font-smoothing: antialiased; }
.shell { max-width: 940px; margin: 0 auto; padding-inline: clamp(1rem, 4vw, 2.25rem); }
a { color: var(--forge); text-decoration-color: rgba(255,106,43,.4); text-underline-offset: .2em; }
a:hover { color: var(--forge-soft); text-decoration-color: currentColor; }
a:focus-visible, button:focus-visible { outline: 2px solid var(--forge); outline-offset: 3px; border-radius: 4px; }
h1, h2, h3 { line-height: 1.2; letter-spacing: -.02em; margin: 0 0 .5em; font-weight: 640; text-wrap: balance; }
h1 { font-size: clamp(2.2rem, 6vw, 3.4rem); }
h2 { font-size: clamp(1.4rem, 3vw, 1.85rem); margin-top: 2.6em; }
h3 { font-size: 1.1rem; margin-top: 1.8em; }
p, li { text-wrap: pretty; }
p { margin: 0 0 1.1em; }
code, pre { font-family: var(--mono); font-size: .9em; }
code:not(pre code) { background: var(--ink-sunken); border: 1px solid var(--line); border-radius: 5px; padding: .12em .4em; }
pre { background: var(--ink-sunken); border: 1px solid var(--line); border-radius: var(--radius); padding: 1rem 1.15rem; overflow-x: auto; margin: 0 0 1.4em; line-height: 1.55; }
pre code { white-space: pre; background: none; border: 0; padding: 0; }
.skip { position: absolute; left: -9999px; }
.skip:focus { left: 1rem; top: 1rem; position: fixed; z-index: 100; background: var(--forge); color: #14060a; padding: .6rem 1rem; border-radius: var(--radius); }
.masthead { border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 20; backdrop-filter: blur(14px); background: rgba(7,8,11,.82); }
.masthead__inner { display: flex; align-items: center; gap: 1.25rem; padding: .8rem 0; }
.masthead nav { margin-left: auto; display: flex; gap: 1.2rem; flex-wrap: wrap; }
.masthead a { color: var(--text-dim); text-decoration: none; font-size: .92rem; }
.masthead a:hover { color: var(--text); }
.brand { font-weight: 680; letter-spacing: -.03em; color: var(--text); text-decoration: none; }
.hero { padding: clamp(3rem, 8vw, 5rem) 0 1rem; }
.eyebrow { display: inline-flex; align-items: center; gap: .5rem; font-family: var(--mono); font-size: .72rem; letter-spacing: .12em; text-transform: uppercase; color: var(--forge); background: var(--forge-glow); border: 1px solid rgba(255,106,43,.3); border-radius: 999px; padding: .3rem .75rem; margin: 0 0 1.25rem; }
.lede { font-size: clamp(1.05rem, 2vw, 1.25rem); color: var(--text-dim); max-width: 60ch; }
.cta-row { display: flex; flex-wrap: wrap; gap: .7rem; margin: 1.75rem 0 0; }
.btn { display: inline-flex; align-items: center; gap: .5rem; padding: .6rem 1.1rem; border-radius: var(--radius); border: 1px solid var(--line-bright); background: var(--ink-raised); color: var(--text); text-decoration: none; font-size: .92rem; font-weight: 520; transition: transform .15s, border-color .15s; }
.btn:hover { transform: translateY(-1px); border-color: var(--forge); color: var(--text); }
.btn--primary { background: var(--forge); border-color: var(--forge); color: #14060a; font-weight: 600; }
.btn--primary:hover { background: var(--forge-soft); border-color: var(--forge-soft); color: #14060a; }
.scene { position: relative; margin: 2.5rem 0 1rem; aspect-ratio: 16 / 5; min-height: 190px; border: 1px solid var(--line); border-radius: var(--radius-lg); background: var(--ink-raised); overflow: hidden; }
.scene canvas { display: block; width: 100%; height: 100%; }
.scene__fallback { position: absolute; inset: 0; display: grid; place-items: center; padding: 1.5rem; margin: 0; text-align: center; color: var(--text-dim); font-size: .92rem; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 1px; background: var(--line); border: 1px solid var(--line); border-radius: var(--radius-lg); overflow: hidden; margin: 2rem 0 0; }
.stat { background: var(--ink-raised); padding: 1.05rem 1.2rem; }
.stat dt { font-size: .72rem; letter-spacing: .08em; text-transform: uppercase; color: var(--text-faint); margin-bottom: .25rem; }
.stat dd { margin: 0; font-size: 1.05rem; font-weight: 600; }
.callout { border: 1px solid var(--line); border-left: 3px solid var(--line-bright); border-radius: var(--radius); background: var(--ink-raised); padding: 1rem 1.15rem; margin: 0 0 1.6em; }
.callout h3 { margin: 0 0 .6rem; font-size: .74rem; text-transform: uppercase; letter-spacing: .09em; color: var(--text-faint); }
.callout p:last-child { margin-bottom: 0; }
.callout--prior { border-left-color: var(--forge); }
.callout--warn { border-left-color: #ff6b8a; }
table { width: 100%; border-collapse: collapse; font-size: .9rem; margin: 0 0 1.6em; display: block; overflow-x: auto; }
th { text-align: left; font-weight: 560; font-size: .72rem; letter-spacing: .07em; text-transform: uppercase; color: var(--text-faint); padding: .5rem .75rem .5rem 0; border-bottom: 1px solid var(--line-bright); white-space: nowrap; }
td { padding: .6rem .75rem .6rem 0; border-bottom: 1px solid var(--line); vertical-align: top; }
tr:last-child td { border-bottom: 0; }
.flags { display: flex; flex-wrap: wrap; gap: .35rem; padding: 0; margin: 0 0 1.5em; list-style: none; }
.flag { font-family: var(--mono); font-size: .74rem; padding: .16rem .45rem; border-radius: 5px; border: 1px solid var(--line); color: var(--text-faint); background: var(--ink-sunken); }
.flag--on { color: var(--forge-soft); border-color: rgba(255,106,43,.4); background: var(--forge-glow); }
.copy { font-family: var(--font); font-size: .72rem; margin-left: .5rem; padding: .1rem .45rem; border-radius: 5px; border: 1px solid var(--line-bright); background: var(--ink-raised); color: var(--text-dim); cursor: pointer; }
.copy:hover { color: var(--text); border-color: var(--forge); }
.foot { border-top: 1px solid var(--line); margin-top: 4rem; padding: 2rem 0 3rem; color: var(--text-faint); font-size: .9rem; }
.foot a { color: var(--text-dim); text-decoration: none; }
.foot a:hover { color: var(--forge); }
`;

const esc = (value) =>
  String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

/** The build script that lands in the repository: no dependencies, reads `hook.json`, writes `dist/`. */
function buildScript(hook, siteUrl, repoUrl, catalogueUrl) {
  return `#!/usr/bin/env node
/**
 * Builds this hook's site.
 *
 * Everything on the page comes from \`hook.json\`, which is generated from the contract, so the page cannot describe
 * the hook as something it is not. No dependencies: run \`node web/build.mjs\` and publish \`web/dist\`.
 */
import {cpSync, mkdirSync, readFileSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, "dist");
const hook = JSON.parse(readFileSync(join(HERE, "..", "hook.json"), "utf8"));

const SITE = ${JSON.stringify(siteUrl)};
const REPO = ${JSON.stringify(repoUrl)};
const CATALOGUE = ${JSON.stringify(catalogueUrl)};

const page = readFileSync(join(HERE, "src", "index.html"), "utf8");

mkdirSync(join(DIST, "assets"), {recursive: true});
writeFileSync(join(DIST, "index.html"), page);
cpSync(join(HERE, "src", "site.css"), join(DIST, "assets", "site.css"));
cpSync(join(HERE, "src", "scene.js"), join(DIST, "assets", "scene.js"));
cpSync(join(HERE, "src", "og.png"), join(DIST, "og.png"));
cpSync(join(HERE, "..", "hook.json"), join(DIST, "hook.json"));

writeFileSync(
  join(DIST, "robots.txt"),
  \`User-agent: *
Allow: /

Sitemap: \${SITE}/sitemap.xml
\`,
);

writeFileSync(
  join(DIST, "sitemap.xml"),
  \`<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>\${SITE}/</loc><lastmod>\${new Date().toISOString().slice(0, 10)}</lastmod><priority>1.0</priority></url>
</urlset>
\`,
);

writeFileSync(
  join(DIST, "llms.txt"),
  \`# \${hook.name}

> \${hook.summary}

A production Uniswap v4 hook. Source: \${REPO}. Part of the HookForge catalogue: \${CATALOGUE}

## How it works
\${hook.description}

## Prior art
\${hook.priorArt}

## Where it does not help
\${hook.limitation}

## Facts
Slug: \${hook.slug}
Contract: \${hook.contract}
Callbacks: \${Object.entries(hook.permissions ?? {}).filter(([, on]) => on).map(([n]) => n).join(", ") || "none"}
Parameters: \${(hook.configure?.fields ?? []).map((f) => f.name + " (" + f.type + ")").join(", ") || "none"}
Dynamic fee required: \${hook.properties?.dynamicFee ? "yes" : "no"}

## Caveats
- Unaudited.
- A deployment with status "deterministic" is a mined CREATE2 address with no code at it yet. Never present one as live.
\`,
);

writeFileSync(
  join(DIST, "_headers"),
  \`/assets/*
  Cache-Control: public, max-age=31536000, immutable

/hook.json
  Cache-Control: public, max-age=300
  Access-Control-Allow-Origin: *

/llms.txt
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *

/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
\`,
);

console.log("built " + hook.slug + " site into web/dist");
`;
}

function indexHtml(hook, {siteUrl, repoUrl, catalogueUrl}) {
  const claimed = claimedFlags(hook);
  const allFlags = [
    "beforeInitialize", "afterInitialize", "beforeAddLiquidity", "afterAddLiquidity",
    "beforeRemoveLiquidity", "afterRemoveLiquidity", "beforeSwap", "afterSwap",
    "beforeDonate", "afterDonate", "beforeSwapReturnsDelta", "afterSwapReturnsDelta",
    "afterAddLiquidityReturnsDelta", "afterRemoveLiquidityReturnsDelta",
  ];

  const md = (text) =>
    paragraphs(text)
      .split("\n\n")
      .filter(Boolean)
      .map((block) => `<p>${esc(block)}</p>`)
      .join("\n      ");

  const table = (markdown) => {
    const rows = markdown.trim().split("\n").filter((line) => line.startsWith("|"));
    if (rows.length < 2) return `<p>${esc(markdown)}</p>`;
    const cells = (line) => line.split("|").slice(1, -1).map((c) => c.trim());
    const head = cells(rows[0]);
    const body = rows.slice(2).map(cells);
    const render = (text) => esc(text).replace(/`([^`]+)`/g, "<code>$1</code>");
    return `<table>
        <thead><tr>${head.map((h) => `<th>${render(h)}</th>`).join("")}</tr></thead>
        <tbody>${body.map((row) => `<tr>${row.map((c) => `<td>${render(c)}</td>`).join("")}</tr>`).join("\n          ")}</tbody>
      </table>`;
  };

  const configureSnippet = hook.configure
    ? `hook.configure(
    key,
    ${hook.contract}.Config({
${(hook.configure.fields ?? []).map((f) => `        ${f.name}: /* ${f.type} */ 0`).join(",\n") || "        // no parameters"}
    })
);

poolManager.initialize(key, startingSqrtPriceX96);`
    : `poolManager.initialize(key, startingSqrtPriceX96);`;

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareSourceCode",
    name: hook.name,
    description: hook.summary,
    url: siteUrl,
    codeRepository: repoUrl,
    programmingLanguage: "Solidity",
    runtimePlatform: "Ethereum Virtual Machine",
    license: "https://opensource.org/licenses/MIT",
    keywords: hook.tags.join(", "),
    isPartOf: {"@type": "WebSite", name: "HookForge", url: catalogueUrl},
  };

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(hook.name)}: ${esc(hook.summary.replace(/\.$/, ""))}</title>
<meta name="description" content="${esc(hook.summary.slice(0, 300))}">
<link rel="canonical" href="${esc(siteUrl)}/">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#07080b">

<meta property="og:type" content="website">
<meta property="og:site_name" content="${esc(hook.name)}">
<meta property="og:title" content="${esc(hook.name)}">
<meta property="og:description" content="${esc(hook.summary.slice(0, 300))}">
<meta property="og:url" content="${esc(siteUrl)}/">
<meta property="og:image" content="${esc(siteUrl)}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(hook.name)}">
<meta name="twitter:description" content="${esc(hook.summary.slice(0, 300))}">
<meta name="twitter:image" content="${esc(siteUrl)}/og.png">

<link rel="stylesheet" href="/assets/site.css">
<link rel="alternate" type="text/plain" title="For language models" href="/llms.txt">
<script type="importmap">{"imports":{"three":"${THREE_CDN}"}}</script>
<script type="application/ld+json">${JSON.stringify(jsonLd)}</script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="masthead">
  <div class="shell masthead__inner">
    <a class="brand" href="/">${esc(hook.name)}</a>
    <nav aria-label="Primary">
      <a href="#how">How it works</a>
      <a href="#using">Using it</a>
      <a href="#deploy">Deploy</a>
      <a href="${esc(repoUrl)}" rel="noopener">GitHub</a>
      <a href="${esc(catalogueUrl)}" rel="noopener">Catalogue</a>
    </nav>
  </div>
</header>

<main id="main">
  <section class="shell hero">
    <p class="eyebrow">Uniswap v4 hook &middot; ${esc(hook.family)}</p>
    <h1>${esc(hook.name)}</h1>
    <p class="lede">${esc(hook.summary)}</p>
    <div class="cta-row">
      <a class="btn btn--primary" href="${esc(repoUrl)}" rel="noopener">Source on GitHub</a>
      <a class="btn" href="#using">Use it in a pool</a>
      <a class="btn" href="/hook.json">Manifest JSON</a>
    </div>

    <div class="scene">
      <canvas data-permissions="${esc(JSON.stringify(hook.permissions ?? {}))}" aria-hidden="true"></canvas>
      <p class="scene__fallback">${esc(hook.name)} implements ${claimed.length} of the fourteen Uniswap v4 callbacks: ${
    claimed.join(", ") || "none"
  }.</p>
    </div>

    <dl class="stats">
      <div class="stat"><dt>Family</dt><dd>${esc(hook.family)}</dd></div>
      <div class="stat"><dt>Callbacks</dt><dd>${claimed.length} of 14</dd></div>
      <div class="stat"><dt>Fee</dt><dd>${hook.properties?.dynamicFee ? "dynamic" : "static"}</dd></div>
      <div class="stat"><dt>Admin keys</dt><dd>none</dd></div>
      <div class="stat"><dt>Licence</dt><dd>MIT</dd></div>
    </dl>
  </section>

  <section class="shell">
    <h2 id="how">How it works</h2>
      ${md(hook.description)}

    ${hook.priorArt ? `<div class="callout callout--prior"><h3>Prior art</h3>${md(hook.priorArt)}</div>` : ""}
    ${hook.limitation ? `<div class="callout callout--warn"><h3>Where it does not help</h3>${md(hook.limitation)}</div>` : ""}

    <h2 id="using">Using it</h2>
    <p>
      Uniswap v4 removed <code>hookData</code> from <code>initialize</code>, so per-pool parameters arrive out of band.
      Fix them for a pool key whose pool does not exist yet, then initialize. Nobody can change them afterwards,
      including you.
    </p>
    <pre><code>${esc(configureSnippet)}</code></pre>
    ${
      hook.properties?.dynamicFee
        ? `<p>The pool's <code>fee</code> field must be <code>LPFeeLibrary.DYNAMIC_FEE_FLAG</code>. The hook rejects a pool initialized without it, which is the most common integration failure.</p>`
        : ""
    }

    <h3>Parameters</h3>
    ${table(parameterTable(hook))}

    <h3>From TypeScript</h3>
    <pre><code>npm i @hookforge/sdk

import {getHook, hookAddress, poolKeyFor} from "@hookforge/sdk";

const hook = getHook("${esc(hook.slug)}");
const key  = poolKeyFor({
  hook: hookAddress("${esc(hook.slug)}", 8453),   // Base
  currencyA: USDC, currencyB: WETH,
  tickSpacing: 60${hook.properties?.dynamicFee ? ", dynamicFee: true" : ""},
});</code></pre>

    ${errorTable(hook) ? `<h2>What it reverts with</h2>\n    ${table(errorTable(hook).split("\n").filter((l) => l.startsWith("|")).join("\n"))}` : ""}

    <h2>The callbacks it claims</h2>
    <p>
      Uniswap v4 reads a hook's permissions from the low fourteen bits of its own address, which is why deploying one
      means mining a CREATE2 salt. This hook claims ${claimed.length}, so every deployment of it has an address ending
      in <code>0x${flagMask(hook).toString(16)}</code>.
    </p>
    <ul class="flags">${allFlags
      .map((flag) => `<li class="flag${hook.permissions?.[flag] ? " flag--on" : ""}">${esc(flag)}</li>`)
      .join("")}</ul>

    <h2>It says what it is, on-chain</h2>
    <p>
      Nothing about a hook's address tells an indexer, a wallet, a router or an agent what the pool does, which is why
      hook discovery today is a curated list. This hook answers for itself, in one <code>eth_call</code>, with no
      registry in the loop.
    </p>
    <pre><code>cast call $HOOK "hookName()(string)"    # ${esc(hook.name)}
cast call $HOOK "specURI()(string)"     # ${esc(siteUrl)}/hook.json
cast call $HOOK "hookTags()(string[])"  # ${esc(hook.tags.join(", "))}</code></pre>

    <h2 id="deploy">Build, test and deploy</h2>
    <pre><code>git clone --recurse-submodules ${esc(repoUrl)}
cd ${esc(hook.slug)}
forge build &amp;&amp; forge test

# Dry run: mines the salt, prints the address, sends nothing.
forge script script/Deploy.s.sol --rpc-url $RPC_URL

# For real.
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify</code></pre>

    <div class="callout callout--warn">
      <h3>Status</h3>
      <p>
        <strong>Unaudited.</strong> Built to an audited shape, on OpenZeppelin's audited hook bases, and tested against
        a real <code>PoolManager</code>. No third party has reviewed it. Read "where it does not help" above before
        putting money behind it. Not affiliated with Uniswap Labs.
      </p>
    </div>
  </section>
</main>

<footer class="foot">
  <div class="shell">
    <p>
      <a href="${esc(repoUrl)}" rel="noopener">Source</a> &middot;
      <a href="/hook.json">Manifest</a> &middot;
      <a href="/llms.txt">llms.txt</a> &middot;
      <a href="${esc(catalogueUrl)}" rel="noopener">The rest of the catalogue</a>
    </p>
    <p>MIT licensed. Not affiliated with Uniswap Labs.</p>
  </div>
</footer>
<script type="module" src="/assets/scene.js"></script>
</body>
</html>
`;
}

/** Writes the whole `web/` tree, including the rasterised social card. */
export function emitSite(repo, hook, {siteUrl, repoUrl, catalogueUrl}) {
  write(repo, "web/build.mjs", buildScript(hook, siteUrl, repoUrl, catalogueUrl));
  write(repo, "web/src/index.html", indexHtml(hook, {siteUrl, repoUrl, catalogueUrl}));
  write(repo, "web/src/site.css", CSS);
  write(repo, "web/src/scene.js", SCENE);
  writeFileSync(join(repo, "web", "src", "og.png"), hookCard(hook));
}
