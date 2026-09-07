/**
 * The demo for a hook that replaces the pool's swap maths with its own.
 *
 * These are the hooks where the interesting thing is the shape of the curve, so the panel is a quoter: type an
 * amount, see what the curve gives back, and watch the reserves and whatever each curve publishes about itself. The
 * quote comes from the contract's own `quote`, so what the page shows is what a swap would receive.
 *
 * Liquidity is fungible on these pools, which makes the panel simpler than a concentrated-liquidity one: deposit both
 * sides, hold shares, burn them to leave. No ranges to pick.
 */
import {formatUnits, parseUnits} from "viem";

import {explorerFor, formatAmount, readableError, shortAddress} from "../wallet.js";
import {clear, el, field, input, row, status} from "../ui.js";

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

const CURVE_ABI = [
  {
    type: "function",
    name: "quote",
    stateMutability: "view",
    inputs: [{type: "bool"}, {type: "bool"}, {type: "uint256"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "reserves",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}, {type: "uint256"}],
  },
  {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "balanceOf", stateMutability: "view", inputs: [{type: "address"}], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "addLiquidity",
    stateMutability: "payable",
    inputs: [
      {
        type: "tuple",
        components: [
          {name: "amount0Desired", type: "uint256"},
          {name: "amount1Desired", type: "uint256"},
          {name: "amount0Min", type: "uint256"},
          {name: "amount1Min", type: "uint256"},
          {name: "deadline", type: "uint256"},
          {name: "tickLower", type: "int24"},
          {name: "tickUpper", type: "int24"},
          {name: "userInputSalt", type: "bytes32"},
        ],
      },
    ],
    outputs: [{type: "int256"}],
  },
];

/** Extra read-only figures a given curve publishes about itself, named in the demo config. */
function statAbi(name) {
  return {type: "function", name, stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]};
}

export function mountCurve(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {reserves: [0n, 0n], tokens: null, shares: 0n, stats: {}};

  const feed = status();
  const stats = el("div", {class: "kv"});
  const quoter = el("div", {class: "quoter"});
  const actions = el("div", {class: "panel__actions"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "Quote this curve"}),
      el("p", {class: "panel__lede", text: demo.lede ?? "Type an amount and see what this curve gives back."}),
    ]),
    stats,
    quoter,
    actions,
    feed.node,
  );

  const abi = [...CURVE_ABI, ...(demo.stats ?? []).map((s) => statAbi(s.name))];

  async function refresh() {
    const {publicClient} = clients;

    const [reserves, supply] = await Promise.all([
      publicClient.readContract({address: deployment.hook, abi, functionName: "reserves"}),
      publicClient.readContract({address: deployment.hook, abi, functionName: "totalSupply"}),
    ]);
    state.reserves = reserves;
    state.supply = supply;

    const [symbol0, decimals0, symbol1, decimals1] = await Promise.all([
      publicClient.readContract({address: deployment.currency0, abi: ERC20_ABI, functionName: "symbol"}),
      publicClient.readContract({address: deployment.currency0, abi: ERC20_ABI, functionName: "decimals"}),
      publicClient.readContract({address: deployment.currency1, abi: ERC20_ABI, functionName: "symbol"}),
      publicClient.readContract({address: deployment.currency1, abi: ERC20_ABI, functionName: "decimals"}),
    ]);
    state.tokens = {symbol0, decimals0, symbol1, decimals1};

    if (session.account) {
      state.shares = await publicClient.readContract({
        address: deployment.hook,
        abi,
        functionName: "balanceOf",
        args: [session.account],
      });
    }

    for (const stat of demo.stats ?? []) {
      try {
        state.stats[stat.name] = await publicClient.readContract({
          address: deployment.hook,
          abi,
          functionName: stat.name,
        });
      } catch {
        state.stats[stat.name] = null; // A curve with no liquidity cannot answer some of these, which is fine.
      }
    }

    render();
  }

  function formatStat(stat, value) {
    if (value === null || value === undefined) return "not available yet";
    if (stat.format === "wad") return (Number(value) / 1e18).toFixed(4);
    if (stat.format === "percent") return `${((Number(value) / 1e18) * 100).toFixed(2)}%`;
    if (stat.format === "q96") return (Number(value) / 2 ** 96).toFixed(4);
    if (stat.format === "bps") return `${(Number(value) / 100).toFixed(2)}%`;
    if (stat.format === "token") return formatAmount(value, 18, 3);
    return value.toString();
  }

  function render() {
    const {tokens} = state;
    clear(stats).append(
      row(`${tokens.symbol0} reserve`, formatAmount(state.reserves[0], tokens.decimals0, 3)),
      row(`${tokens.symbol1} reserve`, formatAmount(state.reserves[1], tokens.decimals1, 3)),
      row("Total shares", formatAmount(state.supply ?? 0n, 18, 3)),
      session.account ? row("Your shares", formatAmount(state.shares, 18, 3)) : null,
      ...(demo.stats ?? []).map((stat) => row(stat.label, formatStat(stat, state.stats[stat.name]))),
    );

    renderQuoter();

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }
    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: "Add liquidity", onclick: addLiquidity}),
      deployment.faucet ? el("button", {class: "btn", type: "button", text: "Get test tokens", onclick: claim}) : null,
    );
  }

  function renderQuoter() {
    const {tokens} = state;
    const amount = input({type: "text", value: "1", inputmode: "decimal", "aria-label": "Amount to sell"});
    const direction = el("select", {class: "input"}, [
      el("option", {value: "0", text: `Sell ${tokens.symbol0} for ${tokens.symbol1}`}),
      el("option", {value: "1", text: `Sell ${tokens.symbol1} for ${tokens.symbol0}`}),
    ]);
    const result = el("div", {class: "quoter__result", text: "—"});

    async function update() {
      const zeroForOne = direction.value === "0";
      const decimals = zeroForOne ? tokens.decimals0 : tokens.decimals1;
      const outSymbol = zeroForOne ? tokens.symbol1 : tokens.symbol0;
      let value;
      try {
        value = parseUnits(amount.value.trim() || "0", decimals);
      } catch {
        result.textContent = "not a number";
        return;
      }
      if (value === 0n) {
        result.textContent = "—";
        return;
      }
      try {
        const out = await clients.publicClient.readContract({
          address: deployment.hook,
          abi,
          functionName: "quote",
          args: [zeroForOne, true, value],
        });
        const outDecimals = zeroForOne ? tokens.decimals1 : tokens.decimals0;
        result.textContent = `${formatAmount(out, outDecimals, 5)} ${outSymbol}`;
      } catch (error) {
        result.textContent = readableError(error);
      }
    }

    amount.addEventListener("input", update);
    direction.addEventListener("change", update);

    clear(quoter).append(
      el("div", {class: "quoter__row"}, [
        field({label: "Amount", input: amount}),
        field({label: "Direction", input: direction}),
      ]),
      el("div", {class: "quoter__out"}, [
        el("span", {class: "quoter__label", text: "The curve gives back"}),
        result,
      ]),
      el("p", {
        class: "compare__hint",
        text: "Quoted by the contract, net of its fee. This is what a swap of that size would actually receive.",
      }),
    );
    update();
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
      feed.set("ok", "Minted.");
    } catch (error) {
      feed.set("error", readableError(error));
    }
  }

  async function addLiquidity() {
    const {publicClient, walletClient} = clients;
    try {
      const amount0 = parseUnits("10", state.tokens.decimals0);
      const amount1 = parseUnits("10", state.tokens.decimals1);

      for (const [token, amount] of [[deployment.currency0, amount0], [deployment.currency1, amount1]]) {
        const allowance = await publicClient.readContract({
          address: token,
          abi: ERC20_ABI,
          functionName: "allowance",
          args: [session.account, deployment.hook],
        });
        if (allowance < amount) {
          feed.set("pending", "Approving…");
          const approval = await walletClient.writeContract({
            address: token,
            abi: ERC20_ABI,
            functionName: "approve",
            args: [deployment.hook, 2n ** 256n - 1n],
            account: session.account,
          });
          await publicClient.waitForTransactionReceipt({hash: approval});
        }
      }

      feed.set("pending", "Adding liquidity…");
      const hash = await walletClient.writeContract({
        address: deployment.hook,
        abi,
        functionName: "addLiquidity",
        args: [
          {
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0n,
            amount1Min: 0n,
            deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: "0x" + "0".repeat(64),
          },
        ],
        account: session.account,
      });
      await publicClient.waitForTransactionReceipt({hash});

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Added. Your shares are a claim on both reserves.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error));
    }
  }

  refresh().catch((error) => feed.set("error", readableError(error)));
  session.onChange(() => refresh().catch((error) => feed.set("error", readableError(error))));
  return {refresh};
}
