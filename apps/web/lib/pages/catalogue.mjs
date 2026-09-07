import {esc, h} from "../html.mjs";
import {page, SITE} from "../layout.mjs";

/** One card. `data-haystack` and `data-tags` are what the client filter reads; the markup works without it. */
export function hookCard(hook) {
  const haystack = [hook.name, hook.slug, hook.family, hook.summary, ...hook.tags].join(" ").toLowerCase();
  return h`
<li class="card" data-haystack="${esc(haystack)}" data-tags="${esc(hook.tags.join(","))}">
  <p class="card__family">${esc(hook.family)}</p>
  <h3 class="card__name"><a href="/hooks/${esc(hook.slug)}/">${esc(hook.name)}</a></h3>
  <p class="card__summary">${esc(hook.summary)}</p>
  <ul class="card__tags">${hook.tags.slice(0, 4).map((tag) => `<li class="tag">${esc(tag)}</li>`).join("")}</ul>
</li>`;
}

/** Cards for hooks in the catalogue but not yet written, so the roadmap is visible and honest. */
function plannedCard(entry) {
  return h`
<li class="card card--soon">
  <p class="card__family">${esc(entry.family)}</p>
  <h3 class="card__name">${esc(entry.name)}</h3>
  <p class="card__summary">${esc(entry.summary)}</p>
  <ul class="card__tags"><li class="tag">planned</li></ul>
</li>`;
}

export function cataloguePage({hooks, planned, assets}) {
  const tags = [...new Set(hooks.flatMap((hook) => hook.tags))].sort();

  const jsonLd = [
    {
      "@context": "https://schema.org",
      "@type": "ItemList",
      name: "HookForge Uniswap v4 hook catalogue",
      description: SITE.description,
      numberOfItems: hooks.length,
      itemListElement: hooks.map((hook, index) => ({
        "@type": "ListItem",
        position: index + 1,
        name: hook.name,
        description: hook.summary,
        url: `${SITE.url}/hooks/${hook.slug}/`,
      })),
    },
  ];

  const body = h`
<section class="shell">
  <div class="prose" style="padding-top:3rem">
    <p class="eyebrow">Catalogue</p>
    <h1>Every hook, and what it is for</h1>
    <p>
      Each of these was checked against the roughly 140 published hooks and hackathon submissions before it was written,
      and each one states its prior art and its limitation on its own page. <strong data-count>${hooks.length}</strong>
      of ${hooks.length + planned.length} are shipped: contract, tests, manifest and documentation all in the repository.
    </p>
  </div>

  <div class="filters">
    <input class="chip" style="flex:1 1 260px;min-width:200px;border-radius:10px;text-align:left"
           type="search" data-search placeholder="Search by problem, e.g. peg, launch, arbitrage    ( / )"
           aria-label="Filter hooks">
    ${tags.map((tag) => `<button class="chip" type="button" data-tag="${esc(tag)}" aria-pressed="false">${esc(tag)}</button>`).join("\n    ")}
  </div>

  <ul class="grid" data-catalogue>
    ${hooks.map(hookCard).join("\n    ")}
  </ul>

  <div class="callout" data-empty hidden>
    <h3>Nothing matched</h3>
    <p>Clear the filter, or search a mechanism word: <code>fee</code>, <code>peg</code>, <code>launch</code>,
      <code>mev</code>, <code>commitment</code>.</p>
  </div>

  ${
    planned.length
      ? h`
  <div class="prose" style="margin-top:4rem">
    <h2>Being built</h2>
    <p>
      The rest of the catalogue, in the order it is being written. These are listed so the shape of the whole is visible;
      nothing here has a contract yet, and nothing here is pretending to.
    </p>
  </div>
  <ul class="grid">
    ${planned.map(plannedCard).join("\n    ")}
  </ul>`
      : ""
  }
</section>`;

  return page({
    title: "Uniswap v4 hook catalogue | HookForge",
    description:
      "Every HookForge Uniswap v4 hook, searchable by the problem it solves: MEV and order flow, curves, risk, liquidity provider economics, launches, time and agent-native mechanisms.",
    path: "/hooks/",
    assets,
    body,
    jsonLd,
    ogImage: `${SITE.url}/og/hooks.png`,
  });
}
