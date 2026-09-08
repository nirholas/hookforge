/**
 * The demo for a hook that holds one position and issues fungible shares in it.
 *
 * A vault is only interesting while you can see it react, so the panel puts the numbers that move at the top: the
 * band the position occupies, how wide it currently is, and how many times it has been forced to move. The swap
 * button is there to push the price out of band and watch all three change at once.
 */
import {explorerFor, readableError} from "../wallet.js";
import {claimBoth, ensureAllowance, formatToken, readPair, swap} from "../pool.js";
import {clear, el, field, input, row, status} from "../ui.js";

/** Builds the ABI for the read-only figures a given vault publishes, named in the demo config. */
function statAbi(stat) {
  return {
    type: "function",
    name: stat.name,
    stateMutability: "view",
    inputs: [],
    outputs: (stat.outputs ?? ["uint256"]).map((type) => ({type})),
  };
}

const VAULT_ABI = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [{name: "amount0Desired", type: "uint256"}, {name: "amount1Desired", type: "uint256"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [{name: "shares", type: "uint256"}],
    outputs: [{type: "uint256"}, {type: "uint256"}],
  },
  {type: "function", name: "balanceOf", stateMutability: "view", inputs: [{type: "address"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{type: "string"}]},
];

export function mountVault(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {stats: {}, shares: 0n, supply: 0n, symbol: "", pair: null, amount: demo.defaultAmount ?? "10"};

  const feed = status();
  const readout = el("div", {class: "kv"});
  const form = el("div", {class: "panel__form"});
  const actions = el("div", {class: "panel__actions"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "One position, fungible shares"}),
      el("p", {class: "panel__lede", text: demo.lede ?? "Deposit both sides, hold shares, watch the position manage itself."}),
    ]),
    readout,
    form,
    actions,
    feed.node,
  );

  const amountInput = input({type: "number", min: "0", step: "1", value: state.amount});
  amountInput.addEventListener("input", () => (state.amount = amountInput.value));
  form.append(
    field({
      label: "Deposit, each side",
      hint: "Both currencies are taken in whatever ratio the position needs. The rest comes straight back.",
      input: amountInput,
    }),
  );

  const stats = demo.stats ?? [];
  const abi = [...VAULT_ABI, ...stats.map(statAbi)];
  const read = (functionName, args) =>
    clients.publicClient.readContract({address: deployment.hook, abi, functionName, args});

  async function refresh() {
    state.pair = await readPair(clients.publicClient, deployment, session.account);
    state.supply = await read("totalSupply", []).catch(() => 0n);
    state.symbol = await read("symbol", []).catch(() => "shares");
    state.shares = session.account ? await read("balanceOf", [session.account]).catch(() => 0n) : 0n;

    for (const stat of stats) {
      state.stats[stat.name] = await read(stat.name, []).catch(() => null);
    }
    render();
  }

  function formatStat(stat, value) {
    if (value === null || value === undefined) return "not available yet";
    if (stat.format === "bool") return value ? "yes" : "no";
    if (stat.format === "ticks") return `${value} ticks`;
    if (stat.format === "token") return formatToken(value, 18, 4);
    if (stat.format === "bps") return `${(Number(value) / 100).toFixed(2)}%`;
    if (stat.format === "time") {
      const seconds = Number(value);
      return seconds > 0 ? new Date(seconds * 1000).toISOString().replace("T", " ").slice(0, 19) : "never";
    }
    return value.toString();
  }

  function toUnits(text, decimals) {
    const [whole = "0", fraction = ""] = String(text || "0").trim().split(".");
    const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
    return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
  }

  function render() {
    clear(readout).append(
      ...stats.map((stat) => row(stat.label, formatStat(stat, state.stats[stat.name]))),
      row("Total shares", formatToken(state.supply, 18, 4)),
      session.account ? row("Your shares", formatToken(state.shares, 18, 4)) : null,
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
      return;
    }

    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: "Deposit", onclick: doDeposit}),
      state.shares > 0n
        ? el("button", {class: "btn", type: "button", text: "Withdraw everything", onclick: doWithdraw})
        : null,
      el("button", {
        class: "btn",
        type: "button",
        text: demo.pushLabel ?? "Push the price",
        title: demo.pushHint ?? "Swap hard enough to move the position and watch the numbers above change.",
        onclick: push,
      }),
      deployment.faucet ? el("button", {class: "btn", type: "button", text: "Get test tokens", onclick: claim}) : null,
    );
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

  async function doDeposit() {
    try {
      const amount0 = toUnits(state.amount, state.pair?.decimals0 ?? 18);
      const amount1 = toUnits(state.amount, state.pair?.decimals1 ?? 18);
      if (amount0 <= 0n && amount1 <= 0n) {
        feed.set("error", "Enter an amount above zero.");
        return;
      }

      feed.set("pending", "Approving both sides…");
      for (const [token, amount] of [
        [deployment.currency0, amount0],
        [deployment.currency1, amount1],
      ]) {
        await ensureAllowance({...clients, account: session.account, token, spender: deployment.hook, amount});
      }

      feed.set("pending", "Depositing…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi,
        functionName: "deposit",
        args: [amount0, amount1],
        account: session.account,
      });
      const receipt = await clients.publicClient.waitForTransactionReceipt({hash});
      if (receipt.status !== "success") throw new Error("The deposit reverted.");

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Deposited. Your shares are a claim on the whole position.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function doWithdraw() {
    try {
      feed.set("pending", "Withdrawing…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi,
        functionName: "withdraw",
        args: [state.shares],
        account: session.account,
      });
      const receipt = await clients.publicClient.waitForTransactionReceipt({hash});
      if (receipt.status !== "success") throw new Error("The withdrawal reverted.");
      feed.set("ok", "Withdrawn, both sides, at whatever ratio the position is holding now.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function push() {
    try {
      feed.set("pending", "Swapping hard enough to matter…");
      await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: true,
        amount: BigInt(demo.pushAmount ?? deployment.demoSwapAmount ?? "10000000000000000"),
      });
      feed.set("ok", demo.pushResult ?? "Pushed. Look at the figures above.");
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
