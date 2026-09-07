/**
 * The demo for a hook that refuses swaps rather than pricing them.
 *
 * These hooks are the ones where a rejected transaction is the product working, not a failure, so the panel is built
 * to make a refusal legible: it shows the state the guard is watching, lets you try a swap, and reports the
 * contract's own error when the guard turns one down. A demo that surfaced that as "transaction failed" would be
 * hiding the exact thing it exists to show.
 */
import {explorerFor, readableError, shortAddress} from "../wallet.js";
import {claimBoth, formatToken, readPair, swap} from "../pool.js";
import {clear, el, row, status} from "../ui.js";

/**
 * Builds a minimal ABI for the read-only calls a given guard publishes.
 *
 * A call may return several figures at once, which several of these hooks do, so a call names its outputs and each
 * displayed row says which one it wants. Flattening that to one output per function would mean either calling the
 * same view three times or quietly showing only its first return value.
 */
function callsAbi(calls) {
  return calls.map((call) => ({
    type: "function",
    name: call.name,
    stateMutability: "view",
    inputs: (call.inputs ?? ["bytes32"]).map((type) => ({type})),
    outputs: (call.outputs ?? ["uint256"]).map((type) => ({type})),
  }));
}

/** A stable key per configured call, so the same view read with different arguments does not collide. */
function keyFor(call) {
  return `${call.name}(${(call.args ?? ["poolId"]).join(",")})`;
}

export function mountGuard(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {stats: {}, pair: null, attempts: []};

  const feed = status();
  const readout = el("div", {class: "kv"});
  const actions = el("div", {class: "panel__actions"});
  const log = el("ul", {class: "attempts"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "What this guard allows"}),
      el("p", {class: "panel__lede", text: demo.lede ?? "Try a swap. A refusal is the hook working, and it will say why."}),
    ]),
    readout,
    actions,
    feed.node,
    log,
  );

  const calls = demo.calls ?? [];
  const abi = callsAbi(calls);

  async function refresh() {
    const {publicClient} = clients;
    for (const call of calls) {
      try {
        // `args` defaults to the pool id, which is what almost every one of these takes.
        const args = (call.args ?? ["poolId"]).map((arg) => (arg === "poolId" ? deployment.poolId : arg));
        const result = await publicClient.readContract({
          address: deployment.hook,
          abi,
          functionName: call.name,
          args,
        });
        state.stats[keyFor(call)] = result;
      } catch {
        // A guard with no pool yet, or one whose state is not knowable, is reported as such rather than as an error.
        state.stats[keyFor(call)] = null;
      }
    }
    state.pair = await readPair(publicClient, deployment, session.account);
    render();
  }

  function formatStat(stat, value) {
    if (value === null || value === undefined) return "not available";
    if (stat.format === "bool") return value ? "yes" : "no";
    if (stat.format === "seconds") return `${value}s`;
    if (stat.format === "bps") return `${(Number(value) / 100).toFixed(2)}%`;
    if (stat.format === "q96") return (Number(value) / 2 ** 96).toFixed(4);
    if (stat.format === "wad") return (Number(value) / 1e18).toFixed(4);
    if (stat.format === "pips") return `${(Number(value) / 10_000).toFixed(4).replace(/0+$/, "").replace(/\.$/, "")}%`;
    return value.toString();
  }

  function render() {
    const rows = [];
    for (const call of calls) {
      const result = state.stats[keyFor(call)];
      for (const read of call.reads ?? [{label: call.label, format: call.format}]) {
        const value =
          result === null || result === undefined
            ? null
            : Array.isArray(result)
              ? result[read.index ?? 0]
              : result;
        rows.push(row(read.label, formatStat(read, value)));
      }
    }

    clear(readout).append(
      ...rows,
      state.pair
        ? row("Your balance", `${formatToken(state.pair.balance0, state.pair.decimals0, 2)} ${state.pair.symbol0}`)
        : null,
    );

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }
    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: demo.tryLabel ?? "Try a swap", onclick: () => attempt(true)}),
      el("button", {class: "btn", type: "button", text: demo.tryOtherLabel ?? "Try the other direction", onclick: () => attempt(false)}),
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

  async function attempt(zeroForOne) {
    try {
      feed.set("pending", "Sending the swap…");
      const hash = await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne,
        amount: BigInt(deployment.demoSwapAmount ?? "10000000000000000"),
      });
      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "The guard allowed it.", link ? {href: link, text: "View"} : null);
      state.attempts.unshift({allowed: true, detail: zeroForOne ? demo.zeroForOneLabel ?? "sell currency0" : demo.oneForZeroLabel ?? "buy currency0"});
    } catch (error) {
      // A refusal is the mechanism working, so it is reported as an outcome rather than as a failure, with the
      // contract's own error rather than a generic message.
      const reason = readableError(error, deployment.errors ?? []);
      feed.set("ok", `The guard refused it: ${reason}`);
      state.attempts.unshift({allowed: false, detail: reason});
    }
    renderLog();
    await refresh();
  }

  function renderLog() {
    clear(log);
    for (const attempt of state.attempts.slice(0, 6)) {
      log.append(
        el("li", {class: `attempt attempt--${attempt.allowed ? "ok" : "refused"}`}, [
          el("span", {class: "attempt__badge", text: attempt.allowed ? "allowed" : "refused"}),
          el("span", {class: "attempt__detail", text: attempt.detail}),
        ]),
      );
    }
  }

  refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? [])));
  session.onChange(() => refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? []))));
  return {refresh};
}
