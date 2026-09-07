/**
 * The demo for a hook that accrues something and lets people claim it.
 *
 * These hooks share a shape: a pot fills from trading, each participant has a share of it, and a claim settles.
 * The panel shows what is owed to the connected account, lets them claim it, and shows the pot so the number is not
 * floating free of anything.
 *
 * The claim form is built from the ABI, because the claims differ: one is keyed on a liquidity position, the other
 * on a closed epoch. A panel that hard-coded either would only work for one of them.
 */
import {explorerFor, readableError} from "../wallet.js";
import {formatToken, readPair, swap} from "../pool.js";
import {clear, el, field, input, row, status} from "../ui.js";

/** Builds the ABI for the reads and the claim a given rewards hook exposes. */
function rewardsAbi(demo) {
  const calls = (demo.calls ?? []).map((call) => ({
    type: "function",
    name: call.name,
    stateMutability: "view",
    inputs: (call.inputs ?? []).map((type) => ({type})),
    outputs: (call.outputs ?? ["uint256"]).map((type) => ({type})),
  }));

  const claim = demo.claim
    ? [
        {
          type: "function",
          name: demo.claim.name,
          stateMutability: "nonpayable",
          inputs: demo.claim.inputs.map((i) => ({type: i.type, name: i.name})),
          outputs: (demo.claim.outputs ?? ["uint256", "uint256"]).map((type) => ({type})),
        },
      ]
    : [];

  return [...calls, ...claim];
}

/** Turns a form value into the type the ABI wants. */
function coerce(type, raw, context) {
  if (raw === "" || raw === undefined) {
    if (type === "address") return context.account;
    if (type.startsWith("uint") || type.startsWith("int")) return 0n;
    if (type === "bytes32") return `0x${"0".repeat(64)}`;
  }
  if (type.startsWith("uint") || type.startsWith("int")) return BigInt(raw);
  return raw;
}

export function mountRewards(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {reads: {}, pair: null, owed: null};

  const feed = status();
  const readout = el("div", {class: "kv"});
  const owed = el("div", {class: "headline"});
  const form = el("div", {class: "claim"});
  const actions = el("div", {class: "panel__actions"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "What you have earned"}),
      el("p", {class: "panel__lede", text: demo.lede ?? "The pot, your share of it, and a button to take it."}),
    ]),
    owed,
    readout,
    form,
    actions,
    feed.node,
  );

  const abi = rewardsAbi(demo);
  const inputs = new Map();

  async function refresh() {
    const {publicClient} = clients;
    state.pair = await readPair(publicClient, deployment, session.account);

    for (const call of demo.calls ?? []) {
      try {
        const args = (call.args ?? []).map((arg) =>
          arg === "poolId" ? deployment.poolId : arg === "account" ? session.account : arg,
        );
        state.reads[call.name] = await publicClient.readContract({
          address: deployment.hook,
          abi,
          functionName: call.name,
          args,
        });
      } catch {
        state.reads[call.name] = null;
      }
    }
    render();
  }

  async function readOwed() {
    if (!demo.owed || !session.account) return null;
    try {
      const args = demo.owed.args.map((arg) => {
        if (arg === "account") return session.account;
        if (arg === "poolId") return deployment.poolId;
        const value = inputs.get(arg)?.value;
        return coerce(demo.owed.types?.[arg] ?? "uint256", value, {account: session.account});
      });
      return await clients.publicClient.readContract({
        address: deployment.hook,
        abi,
        functionName: demo.owed.name,
        args,
      });
    } catch (error) {
      return null;
    }
  }

  function render() {
    const {pair} = state;
    clear(readout).append(
      ...(demo.calls ?? []).map((call) => {
        const result = state.reads[call.name];
        return (call.reads ?? []).map((read) => {
          const value =
            result === null || result === undefined ? null : Array.isArray(result) ? result[read.index ?? 0] : result;
          return row(read.label, value === null ? "not available" : formatRead(read, value, pair));
        });
      }).flat(),
    );

    renderForm();

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }
    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: demo.claimLabel ?? "Claim", onclick: claim}),
      el("button", {class: "btn", type: "button", text: "Swap, to fill the pot", onclick: fillPot}),
    );
  }

  function formatRead(read, value, pair) {
    if (read.format === "bps") return `${(Number(value) / 100).toFixed(2)}%`;
    if (read.format === "token0") return `${formatToken(value, pair.decimals0, 5)} ${pair.symbol0}`;
    if (read.format === "token1") return `${formatToken(value, pair.decimals1, 5)} ${pair.symbol1}`;
    return value.toString();
  }

  function renderForm() {
    clear(form);
    if (!demo.claim) return;

    for (const spec of demo.claim.form ?? []) {
      const node = input({type: "text", value: spec.default ?? "", "aria-label": spec.label});
      inputs.set(spec.name, node);
      node.addEventListener("input", updateOwed);
      form.append(field({label: spec.label, hint: spec.hint, input: node}));
    }
    updateOwed();
  }

  async function updateOwed() {
    const result = await readOwed();
    state.owed = result;
    const {pair} = state;
    clear(owed);
    if (!result || !pair) {
      owed.append(
        el("div", {class: "headline__value", text: "—"}),
        el("div", {class: "headline__label", text: demo.owedLabel ?? "nothing owed yet"}),
      );
      return;
    }
    const [amount0, amount1] = Array.isArray(result) ? result : [result, 0n];
    owed.append(
      el("div", {
        class: "headline__value",
        text: `${formatToken(amount0, pair.decimals0, 5)} ${pair.symbol0}`,
      }),
      el("div", {
        class: "headline__label",
        text: `and ${formatToken(amount1, pair.decimals1, 5)} ${pair.symbol1} ${demo.owedLabel ?? "claimable"}`,
      }),
    );
  }

  async function fillPot() {
    try {
      feed.set("pending", "Swapping, which is what funds the pot…");
      await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: true,
        amount: BigInt(deployment.demoSwapAmount ?? "10000000000000000"),
      });
      feed.set("ok", "Swapped. The skim from that trade is now in the pot.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function claim() {
    try {
      const args = demo.claim.inputs.map((spec) => {
        if (spec.from === "account") return session.account;
        if (spec.from === "poolId") return deployment.poolId;
        return coerce(spec.type, inputs.get(spec.from)?.value, {account: session.account});
      });

      feed.set("pending", "Claiming…");
      const {request} = await clients.publicClient.simulateContract({
        address: deployment.hook,
        abi,
        functionName: demo.claim.name,
        args,
        account: session.account,
      });
      const hash = await clients.walletClient.writeContract(request);
      const receipt = await clients.publicClient.waitForTransactionReceipt({hash});
      if (receipt.status !== "success") throw new Error("The claim reverted on-chain.");

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Claimed, as real tokens.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? [])));
  session.onChange(() => refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? []))));
  return {refresh};
}
