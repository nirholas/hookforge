# hookforge.dev

The catalogue and documentation site. Static HTML generated from the hook registry, with two three.js scenes.

```bash
npm install
npm run build --workspace @hookforge/web   # vite build, then generate the pages
npx serve apps/web/dist
```

## How it is built

`vite build` bundles the client modules and writes a manifest of hashed asset names. `build.mjs` reads that manifest,
renders every page from `packages/registry`, and emits the machine-readable surfaces alongside them. There is no
framework and no content directory: the pages are a pure function of the contracts, so a NatSpec edit in a hook is a
content edit on the site.

| Path | What |
| --- | --- |
| `lib/layout.mjs` | The page shell: canonical URL, Open Graph, Twitter cards, JSON-LD, hashed assets. |
| `lib/pages.mjs` | Home, catalogue and hook page templates. |
| `lib/docs.mjs` | The four documentation pages. |
| `src/hero.js` | Home scene: order flow along a constant-product curve, through the hook. |
| `src/lifecycle.js` | Hook scene: the v4 callback pipeline, with that hook's callbacks lit. |
| `src/main.js` | Catalogue filtering, copy buttons, lazy scene mounting. |

## What it emits beyond HTML

- `/schema/hooks/<slug>.json`: served at exactly the URL each deployed contract returns from `specURI()`, so the
  on-chain pointer resolves to a real document.
- `/api/hooks.json`, `/api/chains.json`, `/api/catalogue.json`: the registry over HTTP, CORS-open.
- `/llms.txt` and `/llms-full.txt`: the catalogue for agents that read documentation instead of crawling it.
- `sitemap.xml`, `robots.txt`, `feed.xml`, and Cloudflare `_headers` with immutable caching for hashed assets.

## Performance and accessibility

The three.js bundle is a lazy chunk, so a documentation page ships about 7 kB of JavaScript and only the home and hook
pages pull the renderer. Both scenes stop rendering when scrolled out of view, draw a single static frame under
`prefers-reduced-motion`, and release their GPU context on `pagehide`. With JavaScript disabled the site is still a
complete, navigable catalogue: every page is real HTML and every scene is decoration over content that already reads.
