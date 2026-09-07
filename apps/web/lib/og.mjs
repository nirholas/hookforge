import {Resvg} from "@resvg/resvg-js";

import {esc} from "./html.mjs";

/**
 * Open Graph cards, drawn as SVG and rasterised at build time.
 *
 * Every page gets its own card rather than one shared image, because a link to a specific hook that previews as a
 * generic logo tells a reader nothing about which hook they are about to open. The card carries the hook's name, its
 * family, its one-line summary and the fourteen permission bits with the ones it claims filled in, so the preview is
 * a genuine summary of the page rather than decoration.
 */

const WIDTH = 1200;
const HEIGHT = 630;

const FAMILY_COLOR = {
  "Order flow and MEV": "#ff6a2b",
  Curves: "#ffc44d",
  "Token mechanics": "#4ecdc4",
  Risk: "#ff6b8a",
  "Liquidity provider economics": "#6ee7b7",
  "Agent-native": "#b58cff",
  Time: "#7cb8ff",
  Launch: "#ffa04d",
  "Cross-domain and information": "#8ad7ff",
};

/** Breaks `text` into at most `maxLines` lines of roughly `perLine` characters, adding an ellipsis if it overflows. */
function wrap(text, perLine, maxLines) {
  const words = String(text ?? "").split(/\s+/).filter(Boolean);
  const lines = [];
  let line = "";

  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (candidate.length > perLine && line) {
      lines.push(line);
      line = word;
      if (lines.length === maxLines) break;
    } else {
      line = candidate;
    }
  }
  if (lines.length < maxLines && line) lines.push(line);

  if (lines.length === maxLines) {
    const consumed = lines.join(" ").split(/\s+/).length;
    if (consumed < words.length) lines[maxLines - 1] = `${lines[maxLines - 1].replace(/[.,;:]$/, "")}…`;
  }
  return lines;
}

/** The fourteen permission bits in address order, so the row reads the same as the low bits of the hook's address. */
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

function card({eyebrow, title, summary, accent = "#ff6a2b", permissions = null, footer}) {
  const titleLines = wrap(title, 24, 2);
  const summaryLines = wrap(summary, 62, 3);

  const bits = permissions
    ? BITS.map((bit, index) => {
        const on = permissions[bit] === true;
        const x = 80 + index * 46;
        return `<rect x="${x}" y="486" width="32" height="32" rx="7" fill="${on ? accent : "#1b1f28"}" stroke="${on ? accent : "#2a303c"}" stroke-width="1.5" opacity="${on ? 1 : 0.85}"/>`;
      }).join("")
    : "";

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#07080b"/>
      <stop offset="1" stop-color="#0d1017"/>
    </linearGradient>
    <linearGradient id="halo" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${accent}" stop-opacity="0.55"/>
      <stop offset="1" stop-color="${accent}" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#bg)"/>
  <rect x="0" y="0" width="${WIDTH}" height="6" fill="url(#halo)"/>
  <circle cx="1080" cy="120" r="220" fill="${accent}" opacity="0.06"/>

  <g transform="translate(80,86)">
    <path d="M0 34V14A11 11 0 0 1 22 14v20a11 11 0 0 0 22 0V0" stroke="${accent}" stroke-width="6" stroke-linecap="round" fill="none"/>
  </g>
  <text x="146" y="126" font-family="Inter, system-ui, sans-serif" font-size="30" font-weight="700" fill="#e8eaef">HookForge</text>

  <text x="80" y="216" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="24" letter-spacing="3" fill="${accent}">${esc(eyebrow.toUpperCase())}</text>

  ${titleLines
    .map((line, index) => `<text x="80" y="${294 + index * 72}" font-family="Inter, system-ui, sans-serif" font-size="66" font-weight="700" fill="#ffffff">${esc(line)}</text>`)
    .join("\n  ")}

  ${summaryLines
    .map(
      (line, index) =>
        `<text x="80" y="${titleLines.length > 1 ? 420 : 372}" dy="${index * 38}" font-family="Inter, system-ui, sans-serif" font-size="27" fill="#9aa3b2">${esc(line)}</text>`,
    )
    .join("\n  ")}

  ${bits}

  <text x="80" y="580" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="23" fill="#6b7280">${esc(footer)}</text>
</svg>`;
}

/** Rasterises one card to PNG bytes. */
export function renderCard(options) {
  const resvg = new Resvg(card(options), {
    background: "#07080b",
    fitTo: {mode: "width", value: WIDTH},
    font: {loadSystemFonts: true, defaultFontFamily: "DejaVu Sans"},
  });
  return resvg.render().asPng();
}

export function hookCard(hook) {
  return renderCard({
    eyebrow: hook.family,
    title: hook.name,
    summary: hook.summary,
    accent: FAMILY_COLOR[hook.family] ?? "#ff6a2b",
    permissions: hook.permissions,
    footer: `hookforge.dev/hooks/${hook.slug}`,
  });
}

export function siteCard({eyebrow, title, summary, footer = "hookforge.dev"}) {
  return renderCard({eyebrow, title, summary, footer});
}
