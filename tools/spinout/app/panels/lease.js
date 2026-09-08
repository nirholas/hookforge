/**
 * The demo for a hook that leases the right to price a pool's flow, one tick range at a time.
 *
 * There is no way to show a Harberger lease except by letting somebody take one, so that is what this is: it reads
 * the range holding the price, shows who holds it and on what terms, and gives you the form to take it off them at
 * the number they published. The two buttons that matter are the ones nobody else can press for you, taking a range
 * and withdrawing what it earned, and both are here.
 */
import {explorerFor, readableError, shortAddress} from "../wallet.js";
import {claimBoth, ensureAllowance, formatToken, poolKeyOf, readPair, swap} from "../pool.js";
import {clear, el, field, input, row, status} from "../ui.js";

const POOL_KEY_COMPONENTS = [
  {name: "currency0", type: "address"},
  {name: "currency1", type: "address"},
  {name: "fee", type: "uint24"},
  {name: "tickSpacing", type: "int24"},
  {name: "hooks", type: "address"},
];

const HOOK_ABI = [
  {
    type: "function",
    name: "configOf",
    stateMutability: "view",
    inputs: [{type: "bytes32"}],
    outputs: [
      {name: "rangeWidth", type: "int24"},
      {name: "rentRateBps", type: "uint32"},
      {name: "maxFeePips", type: "uint24"},
      {name: "minDeposit", type: "uint128"},
    ],
  },
  {
    type: "function",
    name: "leaseOf",
    stateMutability: "view",
    inputs: [{type: "bytes32"}, {type: "int256"}],
    outputs: [
      {name: "holder", type: "address"},
      {name: "feePips", type: "uint24"},
      {name: "valuation", type: "uint128"},
      {name: "deposit", type: "uint128"},
      {name: "activeSince", type: "uint64"},
    ],
  },
  {
    type: "function",
    name: "currentRange",
    stateMutability: "view",
    inputs: [{name: "key", type: "tuple", components: POOL_KEY_COMPONENTS}],
    outputs: [{type: "int256"}],
  },
  {
    type: "function",
    name: "accruedRent",
    stateMutability: "view",
    inputs: [{name: "key", type: "tuple", components: POOL_KEY_COMPONENTS}, {name: "range", type: "int256"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "pendingRent",
    stateMutability: "view",
    inputs: [{type: "bytes32"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "owed",
    stateMutability: "view",
    inputs: [{type: "address"}, {type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [
      {name: "key", type: "tuple", components: POOL_KEY_COMPONENTS},
      {name: "range", type: "int256"},
      {name: "valuation", type: "uint128"},
      {name: "feePips", type: "uint24"},
      {name: "deposit", type: "uint128"},
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "settleRent",
    stateMutability: "nonpayable",
    inputs: [{name: "key", type: "tuple", components: POOL_KEY_COMPONENTS}],
    outputs: [],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [{name: "key", type: "tuple", components: POOL_KEY_COMPONENTS}],
    outputs: [],
  },
];

const ZERO = "0x0000000000000000000000000000000000000000";

/** Parses a decimal string into base units without going through a float, which loses wei. */
function toUnits(text, decimals) {
  const [whole = "0", fraction = ""] = String(text || "0").trim().split(".");
  const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

export function mountLease(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {
    config: null,
    range: null,
    lease: null,
    rent: 0n,
    pending: 0n,
    earned: [0n, 0n],
    pair: null,
    form: {valuation: demo.defaultValuation ?? "1", fee: demo.defaultFee ?? "1.00", deposit: demo.defaultDeposit ?? "0.1"},
  };

  const feed = status();
  const readout = el("div", {class: "kv"});
  const form = el("div", {class: "panel__form"});
  const actions = el("div", {class: "panel__actions"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "Take the range the price is sitting in"}),
      el("p", {
        class: "panel__lede",
        text:
          demo.lede ??
          "Name what the range is worth, pay rent on that number, and set the fee traders pay inside it. Anybody can take it from you at the number you named.",
      }),
    ]),
    readout,
    form,
    actions,
    feed.node,
  );

  const valuationInput = input({type: "number", min: "0", step: "0.01", value: state.form.valuation});
  const feeInput = input({type: "number", min: "0", step: "0.01", value: state.form.fee});
  const depositInput = input({type: "number", min: "0", step: "0.01", value: state.form.deposit});
  valuationInput.addEventListener("input", () => (state.form.valuation = valuationInput.value));
  feeInput.addEventListener("input", () => (state.form.fee = feeInput.value));
  depositInput.addEventListener("input", () => (state.form.deposit = depositInput.value));

  form.append(
    field({
      label: "Your valuation",
      hint: "What you say the range is worth. Rent is charged on this, and anybody may take the range by paying it.",
      input: valuationInput,
    }),
    field({label: "Fee you will charge", hint: "Percent taken from swaps in this range. Capped by the pool.", input: feeInput}),
    field({label: "Rent deposit", hint: "Prepaid rent. When it runs out the lease lapses and the range falls vacant.", input: depositInput}),
  );

  const read = (functionName, args) =>
    clients.publicClient.readContract({address: deployment.hook, abi: HOOK_ABI, functionName, args});

  async function refresh() {
    const key = poolKeyOf(deployment);
    const [config, range, pending] = await Promise.all([
      read("configOf", [deployment.poolId]).catch(() => null),
      read("currentRange", [key]).catch(() => null),
      read("pendingRent", [deployment.poolId]).catch(() => 0n),
    ]);

    state.config = config;
    state.range = range;
    state.pending = pending ?? 0n;

    if (range !== null && range !== undefined) {
      state.lease = await read("leaseOf", [deployment.poolId, range]).catch(() => null);
      state.rent = await read("accruedRent", [key, range]).catch(() => 0n);
    }

    if (session.account) {
      state.earned = await Promise.all([
        read("owed", [session.account, deployment.currency0]).catch(() => 0n),
        read("owed", [session.account, deployment.currency1]).catch(() => 0n),
      ]);
    }

    state.pair = await readPair(clients.publicClient, deployment, session.account);
    render();
  }

  function rentSymbol() {
    return state.pair ? state.pair.symbol1 : "";
  }

  function rentDecimals() {
    return state.pair ? state.pair.decimals1 : 18;
  }

  function render() {
    const lease = state.lease;
    const held = lease && lease[0] !== ZERO;
    const decimals = rentDecimals();

    clear(readout).append(
      row("Range holding the price", state.range === null ? "not available" : state.range.toString()),
      row("Range width", state.config ? `${state.config[0]} ticks` : "not available"),
      row("Rent", state.config ? `${(Number(state.config[1]) / 100).toFixed(2)}% of your valuation per day` : "not available"),
      row("Most a holder may charge", state.config ? `${(Number(state.config[2]) / 10_000).toFixed(2)}%` : "not available"),
      row("Held by", held ? shortAddress(lease[0]) : "nobody, so this range is free to take"),
      held ? row("Their fee", `${(Number(lease[1]) / 10_000).toFixed(2)}%`) : null,
      held ? row("Their price", `${formatToken(lease[2], decimals, 4)} ${rentSymbol()}`) : null,
      held ? row("Deposit left", `${formatToken(lease[3], decimals, 4)} ${rentSymbol()}`) : null,
      held ? row("Rent owed since last charge", `${formatToken(state.rent, decimals, 6)} ${rentSymbol()}`) : null,
      row("Rent waiting for providers", `${formatToken(state.pending, decimals, 6)} ${rentSymbol()}`),
      session.account
        ? row(
            "Your earnings",
            `${formatToken(state.earned[0], state.pair?.decimals0 ?? 18, 6)} ${state.pair?.symbol0 ?? ""} / ${formatToken(state.earned[1], decimals, 6)} ${rentSymbol()}`,
          )
        : null,
    );

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }

    actions.append(
      el("button", {
        class: "btn btn--primary",
        type: "button",
        text: held ? `Take it for ${formatToken(lease[2], decimals, 4)} ${rentSymbol()}` : "Take this range",
        onclick: takeRange,
      }),
      el("button", {class: "btn", type: "button", text: "Swap, and pay the holder's fee", onclick: doSwap}),
      el("button", {class: "btn", type: "button", text: "Send rent to providers", onclick: settle}),
      el("button", {class: "btn", type: "button", text: "Withdraw earnings", onclick: withdraw}),
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

  async function takeRange() {
    try {
      const decimals = rentDecimals();
      const valuation = toUnits(state.form.valuation, decimals);
      const deposit = toUnits(state.form.deposit, decimals);
      // The contract wants hundredths of a bip; the box is a percentage, which is what a person thinks in.
      const feePips = BigInt(Math.round(Number(state.form.fee || "0") * 10_000));

      if (valuation <= 0n) {
        feed.set("error", "A valuation of zero would be a range nobody pays for and anybody takes. Name a real number.");
        return;
      }
      if (state.config && feePips > BigInt(state.config[2])) {
        feed.set("error", `This pool caps a holder's fee at ${(Number(state.config[2]) / 10_000).toFixed(2)}%.`);
        return;
      }

      const price = state.lease && state.lease[0] !== ZERO ? state.lease[2] : 0n;
      feed.set("pending", "Approving the rent token…");
      await ensureAllowance({
        ...clients,
        account: session.account,
        token: deployment.currency1,
        spender: deployment.hook,
        amount: price + deposit,
      });

      feed.set("pending", "Taking the range…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "claim",
        args: [poolKeyOf(deployment), state.range, valuation, Number(feePips), deposit],
        account: session.account,
      });
      const receipt = await clients.publicClient.waitForTransactionReceipt({hash});
      if (receipt.status !== "success") throw new Error("The claim reverted.");

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "You hold the range. Every swap in it now pays your fee, and your rent is running.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function doSwap() {
    try {
      feed.set("pending", "Swapping…");
      const hash = await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: true,
        amount: BigInt(deployment.demoSwapAmount ?? "10000000000000000"),
      });
      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Swapped. The holder of this range was paid their fee.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function settle() {
    try {
      feed.set("pending", "Donating collected rent to the pool's providers…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "settleRent",
        args: [poolKeyOf(deployment)],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      feed.set("ok", "Settled. Rent went to the people whose capital is being priced.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function withdraw() {
    try {
      feed.set("pending", "Withdrawing your fee earnings…");
      const hash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "withdraw",
        args: [poolKeyOf(deployment)],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      feed.set("ok", "Withdrawn as real tokens.");
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
