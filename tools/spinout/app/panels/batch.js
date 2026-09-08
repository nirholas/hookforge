/**
 * The demo for a hook that clears a whole block's orders at one price.
 *
 * The thing to show is that position in the block bought nothing, so the panel lists the orders in the open batch as
 * they arrive, then shows the single price they all cleared at. Placing an order returns no tokens, which surprises
 * people, so the panel says so before you press the button rather than after.
 */
import {explorerFor, readableError, shortAddress} from "../wallet.js";
import {claimBoth, formatToken, poolKeyOf, readPair, swap} from "../pool.js";
import {clear, el, field, input, row, status} from "../ui.js";

const HOOK_ABI = [
  {
    type: "function",
    name: "batchOf",
    stateMutability: "view",
    inputs: [{type: "uint256"}],
    outputs: [
      {name: "blockNumber", type: "uint64"},
      {name: "in0", type: "uint128"},
      {name: "in1", type: "uint128"},
      {name: "price", type: "uint256"},
      {name: "cleared", type: "bool"},
    ],
  },
  {
    type: "function",
    name: "orderOf",
    stateMutability: "view",
    inputs: [{type: "uint256"}, {type: "uint256"}],
    outputs: [
      {name: "owner", type: "address"},
      {name: "zeroForOne", type: "bool"},
      {name: "amountIn", type: "uint128"},
      {name: "collected", type: "bool"},
    ],
  },
  {type: "function", name: "batchCount", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "orderCount", stateMutability: "view", inputs: [{type: "uint256"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "clearable", stateMutability: "view", inputs: [], outputs: [{type: "bool"}]},
  {
    type: "function",
    name: "owed",
    stateMutability: "view",
    inputs: [{type: "uint256"}, {type: "uint256"}],
    outputs: [{type: "uint256"}],
  },
  {type: "function", name: "clear", stateMutability: "nonpayable", inputs: [], outputs: []},
  {
    type: "function",
    name: "collect",
    stateMutability: "nonpayable",
    inputs: [{type: "uint256"}, {type: "uint256"}],
    outputs: [{type: "uint256"}],
  },
  {type: "function", name: "reserve0", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "reserve1", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
];

const ZERO = "0x0000000000000000000000000000000000000000";

/** Parses a decimal string into base units without going through a float, which loses wei. */
function toUnits(text, decimals) {
  const [whole = "0", fraction = ""] = String(text || "0").trim().split(".");
  const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

export function mountBatch(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {
    batches: [],
    clearable: false,
    reserves: [0n, 0n],
    pair: null,
    amount: demo.defaultAmount ?? "1",
    zeroForOne: true,
  };

  const feed = status();
  const readout = el("div", {class: "kv"});
  const form = el("div", {class: "panel__form"});
  const actions = el("div", {class: "panel__actions"});
  const list = el("ul", {class: "attempts"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "One price for the whole block"}),
      el("p", {
        class: "panel__lede",
        text:
          demo.lede ??
          "Every order in a block clears at the same price, so being first is worth nothing. Orders that want opposite sides fill against each other before the curve is touched at all.",
      }),
    ]),
    readout,
    form,
    actions,
    feed.node,
    el("h4", {class: "panel__subhead", text: "Batches"}),
    list,
  );

  const amountInput = input({type: "number", min: "0", step: "0.1", value: state.amount});
  amountInput.addEventListener("input", () => (state.amount = amountInput.value));

  const directionSelect = el("select", {class: "input"}, [
    el("option", {value: "0", text: demo.zeroForOneLabel ?? "Sell currency0"}),
    el("option", {value: "1", text: demo.oneForZeroLabel ?? "Sell currency1"}),
  ]);
  directionSelect.addEventListener("change", () => (state.zeroForOne = directionSelect.value === "0"));

  form.append(
    field({label: "Amount", hint: "What you are paying in. Exact input only, because the price is not known yet.", input: amountInput}),
    field({label: "Direction", hint: "Both directions in one batch fill against each other for free.", input: directionSelect}),
  );

  const read = (functionName, args) =>
    clients.publicClient.readContract({address: deployment.hook, abi: HOOK_ABI, functionName, args});

  async function refresh() {
    state.pair = await readPair(clients.publicClient, deployment, session.account);
    state.clearable = await read("clearable", []).catch(() => false);
    state.reserves = await Promise.all([
      read("reserve0", []).catch(() => 0n),
      read("reserve1", []).catch(() => 0n),
    ]);

    const count = Number(await read("batchCount", []).catch(() => 0n));
    const batches = [];
    // Only the most recent are shown; an unbounded list would slow the page down the longer the pool has run.
    for (let i = Math.max(0, count - 4); i < count; i++) {
      const batch = await read("batchOf", [BigInt(i)]).catch(() => null);
      if (!batch) continue;

      const orders = [];
      const n = Number(await read("orderCount", [BigInt(i)]).catch(() => 0n));
      for (let j = 0; j < Math.min(n, 8); j++) {
        const order = await read("orderOf", [BigInt(i), BigInt(j)]).catch(() => null);
        if (!order || order[0] === ZERO) continue;
        const due = batch[4] ? await read("owed", [BigInt(i), BigInt(j)]).catch(() => 0n) : 0n;
        orders.push({index: j, order, due});
      }
      batches.push({index: i, batch, orders});
    }
    state.batches = batches.reverse();
    render();
  }

  function render() {
    const decimals0 = state.pair?.decimals0 ?? 18;
    const decimals1 = state.pair?.decimals1 ?? 18;

    clear(readout).append(
      row("Reserves", `${formatToken(state.reserves[0], decimals0, 2)} ${state.pair?.symbol0 ?? ""} / ${formatToken(state.reserves[1], decimals1, 2)} ${state.pair?.symbol1 ?? ""}`),
      row("A batch waiting to clear", state.clearable ? "yes, anybody can settle it" : "no"),
      state.pair
        ? row(
            "Your balance",
            `${formatToken(state.pair.balance0, decimals0, 2)} ${state.pair.symbol0} / ${formatToken(state.pair.balance1, decimals1, 2)} ${state.pair.symbol1}`,
          )
        : null,
    );

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      renderList();
      return;
    }

    actions.append(
      el("button", {
        class: "btn btn--primary",
        type: "button",
        text: "Place order",
        title: "This returns no tokens now. It joins the block's batch and you collect once it clears.",
        onclick: place,
      }),
      el("button", {class: "btn", type: "button", text: "Clear the batch", disabled: state.clearable ? null : "disabled", onclick: doClear}),
      deployment.faucet ? el("button", {class: "btn", type: "button", text: "Get test tokens", onclick: claim}) : null,
    );
    renderList();
  }

  function renderList() {
    clear(list);
    if (!state.batches.length) {
      list.append(
        el("li", {
          class: "attempt attempt--idle",
          text: "No batches yet. Place two orders in opposite directions and watch them fill against each other.",
        }),
      );
      return;
    }

    for (const {index, batch, orders} of state.batches) {
      const [blockNumber, in0, in1, price, cleared] = batch;
      list.append(
        el("li", {class: `attempt attempt--${cleared ? "ok" : "idle"}`}, [
          el("span", {class: "attempt__badge", text: cleared ? "cleared" : "open"}),
          el("span", {class: "attempt__detail"}, [
            el("span", {text: `Block ${blockNumber}, ${orders.length} order(s)`}),
            el("span", {
              class: "attempt__muted",
              text: cleared
                ? `one price for everybody: ${(Number(price) / 1e18).toFixed(6)}`
                : "still taking orders",
            }),
          ]),
        ]),
      );

      for (const {index: orderIndex, order, due} of orders) {
        const [owner, zeroForOne, amountIn, collected] = order;
        const mine = session.account && owner.toLowerCase() === session.account.toLowerCase();
        const d = zeroForOne ? state.pair?.decimals0 ?? 18 : state.pair?.decimals1 ?? 18;
        const outDecimals = zeroForOne ? state.pair?.decimals1 ?? 18 : state.pair?.decimals0 ?? 18;

        list.append(
          el("li", {class: "attempt attempt--idle"}, [
            el("span", {class: "attempt__badge", text: shortAddress(owner)}),
            el("span", {class: "attempt__detail"}, [
              el("span", {text: `paid ${formatToken(amountIn, d, 4)} ${zeroForOne ? state.pair?.symbol0 ?? "" : state.pair?.symbol1 ?? ""}`}),
              cleared && !collected
                ? el("span", {class: "attempt__muted", text: `owed ${formatToken(due, outDecimals, 4)}`})
                : el("span", {class: "attempt__muted", text: collected ? "collected" : "awaiting the clearing price"}),
            ]),
            mine && cleared && !collected
              ? el("button", {class: "btn btn--small btn--primary", type: "button", text: "Collect", onclick: () => doCollect(index, orderIndex)})
              : null,
          ]),
        );
      }
    }
  }

  async function claim() {
    try {
      feed.set("pending", "Minting test tokens…");
      await claimBoth({...clients, account: session.account, deployment});
      await refresh();
      feed.set("ok", "Minted.");
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function place() {
    try {
      const decimals = state.zeroForOne ? state.pair?.decimals0 ?? 18 : state.pair?.decimals1 ?? 18;
      const amount = toUnits(state.amount, decimals);
      if (amount <= 0n) {
        feed.set("error", "Enter an amount above zero.");
        return;
      }

      feed.set("pending", "Placing the order. It will not return tokens yet.");
      const hash = await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: state.zeroForOne,
        amount,
        // The owner is named so a router-carried order still belongs to the person who placed it.
        hookData: session.account,
      });
      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "In the batch. It clears once the block is past, at the same price as everyone else in it.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function doClear() {
    try {
      feed.set("pending", "Clearing the batch…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "clear",
        args: [],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      feed.set("ok", "Cleared. Every order in it got the same price.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function doCollect(batch, order) {
    try {
      feed.set("pending", "Collecting…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "collect",
        args: [BigInt(batch), BigInt(order)],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      feed.set("ok", "Collected.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  const onError = (error) => feed.set("error", readableError(error, deployment.errors ?? []));
  refresh().catch(onError);
  session.onChange(() => refresh().catch(onError));

  // Batches turn over per block, so the list has to follow blocks rather than a wall clock.
  clients.publicClient
    .watchBlockNumber({emitOnBegin: false, onBlockNumber: () => refresh().catch(onError)})
    ?.catch?.(() => {});

  return {refresh};
}
