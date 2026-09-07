/**
 * The demo for a hook that prices swaps by overriding the pool's fee.
 *
 * One panel serves nine of them, because they all answer the same two questions: what would this pool charge me right
 * now, and why. The "why" is a curve, and the curve is read from the contract rather than reimplemented here, so what
 * the chart draws is what the pool will actually charge. A front end that recomputed the formula in JavaScript would
 * be right until somebody changed the Solidity.
 */
import {formatUnits} from "viem";

import {explorerFor, formatAmount, readableError, shortAddress} from "../wallet.js";
import {clear, code, el, row, status} from "../ui.js";

const ROUTER_ABI = [
  {
    type: "function",
    name: "swap",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
      {
        name: "params",
        type: "tuple",
        components: [
          {name: "zeroForOne", type: "bool"},
          {name: "amountSpecified", type: "int256"},
          {name: "sqrtPriceLimitX96", type: "uint160"},
        ],
      },
      {name: "hookData", type: "bytes"},
    ],
    outputs: [{type: "int256"}],
  },
];

const ERC20_ABI = [
  {type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
  {type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{type: "uint8"}]},
  {type: "function", name: "claim", stateMutability: "nonpayable", inputs: [], outputs: []},
  {type: "function", name: "balanceOf", stateMutability: "view", inputs: [{type: "address"}], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [{type: "address"}, {type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{type: "address"}, {type: "uint256"}],
    outputs: [{type: "bool"}],
  },
];

const MIN_SQRT_PRICE_LIMIT = 4295128740n;
const MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

function feeText(pips) {
  return `${(Number(pips) / 10_000).toFixed(4).replace(/0+$/, "").replace(/\.$/, "")}%`;
}

/**
 * Draws the fee curve as inline SVG.
 *
 * Inline rather than a chart library because the whole picture is one polyline over a linear axis, and shipping a
 * charting dependency to draw it would be more code than the chart. The points come from the chain.
 */
function chart(points, {xLabel, yLabel, marker}) {
  if (points.length < 2) return el("p", {class: "compare__hint", text: "Not enough points to draw the curve."});

  const width = 560;
  const height = 190;
  const pad = {top: 14, right: 14, bottom: 30, left: 52};

  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const xMin = Math.min(...xs);
  const xMax = Math.max(...xs);
  const yMin = Math.min(...ys);
  const yMax = Math.max(...ys);
  const ySpan = yMax - yMin || 1;

  const px = (x) => pad.left + ((x - xMin) / (xMax - xMin || 1)) * (width - pad.left - pad.right);
  const py = (y) => height - pad.bottom - ((y - yMin) / ySpan) * (height - pad.top - pad.bottom);

  const line = points.map((p) => `${px(p.x).toFixed(1)},${py(p.y).toFixed(1)}`).join(" ");
  const area = `${pad.left},${height - pad.bottom} ${line} ${px(xMax).toFixed(1)},${height - pad.bottom}`;

  const ticks = [yMin, yMin + ySpan / 2, yMax].map(
    (value) =>
      `<g><line x1="${pad.left}" y1="${py(value).toFixed(1)}" x2="${width - pad.right}" y2="${py(value).toFixed(1)}" stroke="#1b1f28"/>` +
      `<text x="${pad.left - 8}" y="${(py(value) + 4).toFixed(1)}" text-anchor="end" fill="#868e9c" font-size="10">${feeText(value)}</text></g>`,
  );

  const markerSvg =
    marker && marker.x >= xMin && marker.x <= xMax
      ? `<line x1="${px(marker.x).toFixed(1)}" y1="${pad.top}" x2="${px(marker.x).toFixed(1)}" y2="${height - pad.bottom}" stroke="#ff6a2b" stroke-dasharray="3 3"/>` +
        `<circle cx="${px(marker.x).toFixed(1)}" cy="${py(marker.y).toFixed(1)}" r="4" fill="#ff6a2b"/>`
      : "";

  return el("figure", {class: "chart"}, [
    el("div", {
      class: "chart__svg",
      html:
        `<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="${yLabel} against ${xLabel}">` +
        ticks.join("") +
        `<polyline points="${area}" fill="rgba(255,106,43,.08)" stroke="none"/>` +
        `<polyline points="${line}" fill="none" stroke="#ff6a2b" stroke-width="2" stroke-linejoin="round"/>` +
        markerSvg +
        `<text x="${width / 2}" y="${height - 8}" text-anchor="middle" fill="#868e9c" font-size="10">${xLabel}</text>` +
        `</svg>`,
    }),
    el("figcaption", {class: "chart__caption", text: `${yLabel} against ${xLabel}, read from the contract.`}),
  ]);
}

export function mountFeeHook(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {liveFee: null, curve: [], marker: null, tokens: null, results: []};

  const feed = status();
  const headline = el("div", {class: "headline"});
  const chartPane = el("div");
  const detail = el("div", {class: "kv"});
  const actions = el("div", {class: "panel__actions"});
  const comparison = el("div", {class: "compare"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "What this pool charges"}),
      el("p", {class: "panel__lede", text: demo.lede ?? "The fee this hook quotes, live, and the curve behind it."}),
    ]),
    headline,
    chartPane,
    detail,
    actions,
    feed.node,
    comparison,
  );

  const hookAbi = [
    {
      type: "function",
      name: demo.liveFee?.name ?? "quoteFee",
      stateMutability: "view",
      inputs: [{type: "bytes32"}],
      outputs: [{type: "uint24"}],
    },
    demo.curve
      ? {
          type: "function",
          name: demo.curve.name,
          stateMutability: "view",
          inputs: [{type: "bytes32"}, {type: "uint256"}],
          outputs: [{type: "uint24"}],
        }
      : null,
  ].filter(Boolean);

  async function refresh() {
    const {publicClient} = clients;

    state.liveFee = await publicClient.readContract({
      address: deployment.hook,
      abi: hookAbi,
      functionName: demo.liveFee?.name ?? "quoteFee",
      args: [deployment.poolId],
    });

    if (demo.curve) {
      const {from, to, steps = 24, scale = 1} = demo.curve;
      const points = [];
      for (let i = 0; i <= steps; i++) {
        const x = from + ((to - from) * i) / steps;
        const fee = await publicClient.readContract({
          address: deployment.hook,
          abi: hookAbi,
          functionName: demo.curve.name,
          args: [deployment.poolId, BigInt(Math.round(x))],
        });
        points.push({x: x / scale, y: Number(fee)});
      }
      state.curve = points;
    }

    if (session.account) {
      const [symbol0, decimals0, balance0] = await Promise.all([
        publicClient.readContract({address: deployment.currency0, abi: ERC20_ABI, functionName: "symbol"}),
        publicClient.readContract({address: deployment.currency0, abi: ERC20_ABI, functionName: "decimals"}),
        publicClient.readContract({
          address: deployment.currency0,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [session.account],
        }),
      ]);
      state.tokens = {symbol0, decimals0, balance0};
    }

    render();
  }

  function render() {
    clear(headline).append(
      el("div", {class: "headline__value", text: feeText(state.liveFee ?? 0)}),
      el("div", {class: "headline__label", text: demo.liveLabel ?? "the fee this pool is quoting right now"}),
    );

    clear(chartPane);
    if (demo.curve && state.curve.length) {
      chartPane.append(
        chart(state.curve, {
          xLabel: demo.curve.xLabel,
          yLabel: "fee",
          marker: null,
        }),
      );
    }

    clear(detail).append(
      row("Pool", shortAddress(deployment.hook)),
      row("Router", shortAddress(deployment.router)),
      state.tokens ? row("Your balance", `${formatAmount(state.tokens.balance0, state.tokens.decimals0, 3)} ${state.tokens.symbol0}`) : null,
    );

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }
    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: "Swap and see the fee applied", onclick: runSwap}),
      deployment.faucet
        ? el("button", {class: "btn", type: "button", text: "Get test tokens", onclick: claim})
        : null,
    );
  }

  async function claim() {
    try {
      feed.set("pending", "Minting test tokens…");
      for (const token of [deployment.currency0, deployment.currency1]) {
        const hash = await clients.walletClient.writeContract({
          address: token,
          abi: ERC20_ABI,
          functionName: "claim",
          account: session.account,
        });
        await clients.publicClient.waitForTransactionReceipt({hash});
      }
      await refresh();
      feed.set("ok", "Minted. You can swap now.");
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function runSwap() {
    const {publicClient, walletClient} = clients;
    try {
      const amount = BigInt(deployment.demoSwapAmount ?? "10000000000000000");
      const inputToken = deployment.zeroForOne ? deployment.currency0 : deployment.currency1;

      const allowance = await publicClient.readContract({
        address: inputToken,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [session.account, deployment.router],
      });
      if (allowance < amount) {
        feed.set("pending", "Approving the router…");
        const approval = await walletClient.writeContract({
          address: inputToken,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [deployment.router, 2n ** 256n - 1n],
          account: session.account,
        });
        await publicClient.waitForTransactionReceipt({hash: approval});
      }

      const quoted = state.liveFee;
      feed.set("pending", `Swapping at ${feeText(quoted)}…`);
      const hash = await walletClient.writeContract({
        address: deployment.router,
        abi: ROUTER_ABI,
        functionName: "swap",
        args: [
          {
            currency0: deployment.currency0,
            currency1: deployment.currency1,
            fee: deployment.fee,
            tickSpacing: deployment.tickSpacing,
            hooks: deployment.hook,
          },
          {
            zeroForOne: deployment.zeroForOne,
            amountSpecified: -amount,
            sqrtPriceLimitX96: deployment.zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
          },
          "0x",
        ],
        account: session.account,
      });
      const receipt = await publicClient.waitForTransactionReceipt({hash});
      if (receipt.status !== "success") throw new Error("The swap reverted on-chain.");

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", `Swapped at ${feeText(quoted)}.`, link ? {href: link, text: "View"} : null);
      state.results.push({fee: quoted});
      renderComparison();
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  function renderComparison() {
    clear(comparison);
    if (state.results.length < 2) {
      comparison.append(
        el("p", {
          class: "compare__hint",
          text: demo.compareHint ?? "Swap more than once to watch the quoted fee move as the mechanism responds.",
        }),
      );
      return;
    }
    const first = state.results[0];
    const latest = state.results.at(-1);
    comparison.append(
      el("div", {class: "compare__grid"}, [
        el("div", {class: "compare__cell"}, [
          el("span", {class: "compare__label", text: "Your first swap"}),
          el("span", {class: "compare__value", text: feeText(first.fee)}),
        ]),
        el("div", {class: "compare__cell compare__cell--win"}, [
          el("span", {class: "compare__label", text: "Your latest"}),
          el("span", {class: "compare__value", text: feeText(latest.fee)}),
        ]),
      ]),
    );
  }

  refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? [])));
  session.onChange(() => refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? []))));
  return {refresh};
}
