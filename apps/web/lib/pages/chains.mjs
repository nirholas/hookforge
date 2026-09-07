import {esc, h, copyable} from "../html.mjs";
import {page, SITE} from "../layout.mjs";

const TARGETS = new Set(["base", "arbitrum", "unichain", "robinhood"]);

export function chainsPage({chains, hooks, assets}) {
  const rows = chains.map((chain) => {
    const deployed = hooks.filter((hook) => hook.deployments.some((d) => d.chainId === chain.chainId));
    return {...chain, count: deployed.length};
  });

  const jsonLd = [
    {
      "@context": "https://schema.org",
      "@type": "Dataset",
      name: "Uniswap v4 PoolManager address book",
      description:
        "Chain id and PoolManager address for every chain HookForge targets, kept in the Solidity source the hooks deploy against.",
      url: `${SITE.url}/chains/`,
      license: "https://www.apache.org/licenses/LICENSE-2.0",
      creator: {"@type": "Organization", name: SITE.name, url: SITE.url},
    },
  ];

  const body = h`
<section class="shell">
  <div class="prose" style="padding-top:3rem">
    <p class="eyebrow">Deployment</p>
    <h1>Chains and addresses</h1>
    <p>
      HookForge targets four chains first: <strong>Base</strong>, <strong>Arbitrum One</strong>,
      <strong>Unichain</strong> and <strong>Robinhood Chain</strong>. The hooks are plain v4 hooks with no chain-specific
      code, so they build and deploy against any chain with a <code>PoolManager</code>; the rest of the table is there
      because the address book is generated from the same Solidity the deploy script reads.
    </p>
    <p>
      Every address below was taken from Uniswap's published deployments and lives in
      <a href="${esc(SITE.repo)}/blob/main/contracts/src/libraries/Chains.sol" rel="noopener"><code>Chains.sol</code></a>,
      so a deploy script and this page cannot disagree.
    </p>
  </div>

  <table class="addresses">
    <thead>
      <tr><th>Chain</th><th>Chain ID</th><th>PoolManager</th><th>Hooks</th></tr>
    </thead>
    <tbody>
      ${rows
        .map(
          (chain) => `<tr>
        <td>${esc(chain.slug)}${TARGETS.has(chain.slug) ? ' <span class="tag">target</span>' : ""}</td>
        <td><code>${esc(chain.chainId)}</code></td>
        <td>${copyable(chain.poolManager)}</td>
        <td>${chain.count}</td>
      </tr>`,
        )
        .join("\n      ")}
    </tbody>
  </table>

  <div class="prose" style="margin-top:3rem">
    <h2>Deterministic addresses</h2>
    <p>
      A Uniswap v4 hook has to live at an address whose low fourteen bits are exactly the permission flags it declares,
      which is why hook addresses all end in the same handful of patterns. The deploy script mines a CREATE2 salt until
      the address matches, then deploys through the canonical deterministic factory, so the same hook lands on the same
      address on every chain.
    </p>
    <p>
      Addresses published before a deploy are marked <code>deterministic</code> in the registry and on the hook page.
      That means the address is known and reserved by the maths, not that there is code at it yet. The
      <code>status</code> field is carried through <a href="/api/hooks.json">the registry JSON</a> for exactly this
      reason: a client should never render a predicted address as a live one.
    </p>
    <pre><code>cd contracts
forge script script/DeployHooks.s.sol \\
  --rpc-url $BASE_RPC_URL --broadcast --verify</code></pre>
  </div>
</section>`;

  return page({
    title: "Chains and PoolManager addresses | HookForge",
    description:
      "Chain id and Uniswap v4 PoolManager address for Base, Arbitrum One, Unichain, Robinhood Chain and every other chain HookForge builds against, with the deterministic hook addresses each one deploys to.",
    path: "/chains/",
    assets,
    body,
    jsonLd,
    ogImage: `${SITE.url}/og/chains.png`,
  });
}
