/**
 * The demo for a hook that runs standing value-averaging orders inside other people's swaps.
 *
 * The thing worth showing is not that a stream exists but that its next buy changes with the price, so the panel puts
 * the number that moves right next to the schedule that does not: what is due now, against what a fixed-size plan
 * would have spent. Moving the pool and watching that figure change is the demo.
 */
import {explorerFor, readableError} from "../wallet.js";
import {claimBoth, ensureAllowance, formatToken, poolKeyOf, readPair, swap} from "../pool.js";
import {clear, el, field, input, row, status} from "../ui.js";

const POOL_KEY_COMPONENTS = [
  {name: "currency0", type: "address"},
  {name: "currency1", type: "address"},
  {name: "fee", type: "uint24"},
  {name: "tickSpacing", type: "int24"},
  {name: "hooks", type: "address"},
];

const KEY = {name: "key", type: "tuple", components: POOL_KEY_COMPONENTS};

const HOOK_ABI = [
  {
    type: "function",
    name: "open",
    stateMutability: "nonpayable",
    inputs: [
      KEY,
      {name: "zeroForOne", type: "bool"},
      {name: "budget", type: "uint128"},
      {name: "targetPerPeriod", type: "uint128"},
      {name: "periodLength", type: "uint64"},
      {name: "periods", type: "uint32"},
    ],
    outputs: [{type: "uint256"}],
  },
  {type: "function", name: "close", stateMutability: "nonpayable", inputs: [KEY, {name: "stream", type: "uint256"}], outputs: []},
  {type: "function", name: "poke", stateMutability: "nonpayable", inputs: [KEY], outputs: []},
  {
    type: "function",
    name: "streamOf",
    stateMutability: "view",
    inputs: [{type: "bytes32"}, {type: "uint256"}],
    outputs: [
      {name: "owner", type: "address"},
      {name: "zeroForOne", type: "bool"},
      {name: "remaining", type: "uint128"},
      {name: "acquired", type: "uint128"},
      {name: "targetPerPeriod", type: "uint128"},
      {name: "periodLength", type: "uint64"},
      {name: "startedAt", type: "uint64"},
      {name: "periodsDone", type: "uint32"},
      {name: "periods", type: "uint32"},
    ],
  },
  {type: "function", name: "streamCount", stateMutability: "view", inputs: [{type: "bytes32"}], outputs: [{type: "uint256"}]},
  {
    type: "function",
    name: "spendDue",
    stateMutability: "view",
    inputs: [KEY, {name: "stream", type: "uint256"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "periodsDue",
    stateMutability: "view",
    inputs: [KEY, {name: "stream", type: "uint256"}],
    outputs: [{type: "uint32"}],
  },
];

const ZERO = "0x0000000000000000000000000000000000000000";

/** Parses a decimal string into base units without going through a float, which loses wei. */
function toUnits(text, decimals) {
  const [whole = "0", fraction = ""] = String(text || "0").trim().split(".");
  const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

export function mountStream(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {
    streams: [],
    pair: null,
    form: {
      zeroForOne: true,
      budget: demo.defaultBudget ?? "10",
      perPeriod: demo.defaultPerPeriod ?? "1",
      periodMinutes: demo.defaultPeriodMinutes ?? "1",
      periods: demo.defaultPeriods ?? "10",
    },
  };

  const feed = status();
  const intro = el("div", {class: "kv"});
  const form = el("div", {class: "panel__form"});
  const actions = el("div", {class: "panel__actions"});
  const list = el("ul", {class: "attempts"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "A standing order that buys more when the price falls"}),
      el("p", {
        class: "panel__lede",
        text:
          demo.lede ??
          "Commit to growing the position by a fixed amount each period, not to spending a fixed amount. Move the pool and watch the next buy resize itself.",
      }),
    ]),
    intro,
    form,
    actions,
    feed.node,
    el("h4", {class: "panel__subhead", text: "Streams on this pool"}),
    list,
  );

  const budgetInput = input({type: "number", min: "0", step: "0.1", value: state.form.budget});
  const perPeriodInput = input({type: "number", min: "0", step: "0.1", value: state.form.perPeriod});
  const periodInput = input({type: "number", min: "1", step: "1", value: state.form.periodMinutes});
  const periodsInput = input({type: "number", min: "1", step: "1", value: state.form.periods});
  const directionSelect = el("select", {class: "input"}, [
    el("option", {value: "0", text: demo.zeroForOneLabel ?? "Spend currency0, buy currency1"}),
    el("option", {value: "1", text: demo.oneForZeroLabel ?? "Spend currency1, buy currency0"}),
  ]);

  budgetInput.addEventListener("input", () => (state.form.budget = budgetInput.value));
  perPeriodInput.addEventListener("input", () => (state.form.perPeriod = perPeriodInput.value));
  periodInput.addEventListener("input", () => (state.form.periodMinutes = periodInput.value));
  periodsInput.addEventListener("input", () => (state.form.periods = periodsInput.value));
  directionSelect.addEventListener("change", () => (state.form.zeroForOne = directionSelect.value === "0"));

  form.append(
    field({label: "Direction", hint: "What the stream spends, and what it accumulates.", input: directionSelect}),
    field({label: "Budget", hint: "The most this stream will ever spend. Pulled up front, refunded if unused.", input: budgetInput}),
    field({
      label: "Value gained per period",
      hint: "Not what you spend. What the position should be worth more by, which is what makes the buy resize.",
      input: perPeriodInput,
    }),
    field({label: "Period length (minutes)", hint: "How often the target steps up.", input: periodInput}),
    field({label: "Periods", hint: "How many steps before the stream is finished.", input: periodsInput}),
  );

  const read = (functionName, args) =>
    clients.publicClient.readContract({address: deployment.hook, abi: HOOK_ABI, functionName, args});

  async function refresh() {
    const key = poolKeyOf(deployment);
    state.pair = await readPair(clients.publicClient, deployment, session.account);

    const count = Number(await read("streamCount", [deployment.poolId]).catch(() => 0n));
    const streams = [];
    // Only the most recent are shown: an unbounded list would make the page slower the longer the pool has run.
    for (let i = Math.max(0, count - 12); i < count; i++) {
      const raw = await read("streamOf", [deployment.poolId, BigInt(i)]).catch(() => null);
      if (!raw || raw[0] === ZERO) continue;
      const [due, periods] = await Promise.all([
        read("spendDue", [key, BigInt(i)]).catch(() => 0n),
        read("periodsDue", [key, BigInt(i)]).catch(() => 0),
      ]);
      streams.push({index: i, raw, due, periodsDue: Number(periods)});
    }
    state.streams = streams;
    render();
  }

  function decimalsFor(zeroForOne) {
    if (!state.pair) return {spend: 18, acquire: 18, spendSymbol: "", acquireSymbol: ""};
    return zeroForOne
      ? {spend: state.pair.decimals0, acquire: state.pair.decimals1, spendSymbol: state.pair.symbol0, acquireSymbol: state.pair.symbol1}
      : {spend: state.pair.decimals1, acquire: state.pair.decimals0, spendSymbol: state.pair.symbol1, acquireSymbol: state.pair.symbol0};
  }

  function render() {
    clear(intro).append(
      row("How a period is sized", "Target value minus what the position is already worth"),
      row("Settled by", "The next swap anyone makes, or the poke button below"),
      state.pair
        ? row(
            "Your balance",
            `${formatToken(state.pair.balance0, state.pair.decimals0, 2)} ${state.pair.symbol0} / ${formatToken(state.pair.balance1, state.pair.decimals1, 2)} ${state.pair.symbol1}`,
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
      el("button", {class: "btn btn--primary", type: "button", text: "Open this stream", onclick: openStream}),
      el("button", {
        class: "btn",
        type: "button",
        text: "Move the price",
        title: "Swap against the pool, so the next period has to resize itself.",
        onclick: movePrice,
      }),
      el("button", {class: "btn", type: "button", text: "Settle what is due", onclick: poke}),
      deployment.faucet ? el("button", {class: "btn", type: "button", text: "Get test tokens", onclick: claim}) : null,
    );
    renderList();
  }

  function renderList() {
    clear(list);
    if (!state.streams.length) {
      list.append(
        el("li", {
          class: "attempt attempt--idle",
          text: "No open streams. Open one and it appears here with the size of its next buy, which changes as the pool moves.",
        }),
      );
      return;
    }

    for (const {index, raw, due, periodsDue} of state.streams) {
      const [owner, zeroForOne, remaining, acquired, targetPerPeriod, , , periodsDone, periods] = raw;
      const d = decimalsFor(zeroForOne);
      const mine = session.account && owner.toLowerCase() === session.account.toLowerCase();
      const target = formatToken(targetPerPeriod, d.spend, 4);
      const dueText = periodsDue > 0 ? `${formatToken(due, d.spend, 4)} ${d.spendSymbol}` : "nothing due yet";

      list.append(
        el("li", {class: `attempt attempt--${periodsDue > 0 ? "ok" : "idle"}`}, [
          el("span", {class: "attempt__badge", text: `${periodsDone}/${periods}`}),
          el("span", {class: "attempt__detail"}, [
            el("span", {text: `Next buy: ${dueText}`}),
            el("span", {class: "attempt__muted", text: `flat plan would spend ${target} ${d.spendSymbol}`}),
            el("span", {
              class: "attempt__muted",
              text: `holds ${formatToken(acquired, d.acquire, 4)} ${d.acquireSymbol}, ${formatToken(remaining, d.spend, 4)} ${d.spendSymbol} left`,
            }),
          ]),
          mine ? el("button", {class: "btn btn--small", type: "button", text: "Close", onclick: () => closeStream(index)}) : null,
        ]),
      );
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

  async function openStream() {
    try {
      const {zeroForOne} = state.form;
      const d = decimalsFor(zeroForOne);
      const budget = toUnits(state.form.budget, d.spend);
      const perPeriod = toUnits(state.form.perPeriod, d.spend);
      const periodLength = BigInt(Math.max(1, Math.round(Number(state.form.periodMinutes || "1") * 60)));
      const periods = BigInt(Math.max(1, Math.round(Number(state.form.periods || "1"))));

      if (budget <= 0n || perPeriod <= 0n) {
        feed.set("error", "A stream needs a budget and a per-period target above zero.");
        return;
      }

      const token = zeroForOne ? deployment.currency0 : deployment.currency1;
      feed.set("pending", "Approving the budget…");
      await ensureAllowance({...clients, account: session.account, token, spender: deployment.hook, amount: budget});

      feed.set("pending", "Opening the stream…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "open",
        args: [poolKeyOf(deployment), zeroForOne, budget, perPeriod, periodLength, Number(periods)],
        account: session.account,
      });
      const receipt = await clients.publicClient.waitForTransactionReceipt({hash});
      if (receipt.status !== "success") throw new Error("Opening the stream reverted.");

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Open. It buys nothing until the first period ends, then resizes itself every period after that.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function movePrice() {
    try {
      feed.set("pending", "Swapping against the pool…");
      await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: !state.form.zeroForOne,
        amount: BigInt(deployment.demoSwapAmount ?? "10000000000000000"),
      });
      feed.set("ok", "Moved. Every open stream just repriced its next buy.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function poke() {
    try {
      feed.set("pending", "Settling everything that is due…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "poke",
        args: [poolKeyOf(deployment)],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      feed.set("ok", "Settled. On a busy pool this rides along inside somebody else's swap for free.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function closeStream(index) {
    try {
      feed.set("pending", "Closing the stream…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "close",
        args: [poolKeyOf(deployment), BigInt(index)],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      feed.set("ok", "Closed. What it bought and whatever it never spent are both back in your wallet.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  const onError = (error) => feed.set("error", readableError(error, deployment.errors ?? []));
  refresh().catch(onError);
  session.onChange(() => refresh().catch(onError));
  return {refresh};
}
