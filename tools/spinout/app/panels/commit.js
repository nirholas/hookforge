/**
 * The demo for a hook whose swaps must be committed to in an earlier block.
 *
 * A guard panel would only ever show this hook refusing things, which is half the product. The whole point is the
 * two-phase trade, so this panel is built around it: it generates the salt, holds it locally, makes the commitment,
 * counts the blocks down, and then reveals by sending the swap the commitment described. The salt never leaves the
 * browser until the reveal, because a salt that reached a server would make the commitment worthless.
 */
import {explorerFor, readableError, shortAddress} from "../wallet.js";
import {MAX_SQRT_PRICE_LIMIT, MIN_SQRT_PRICE_LIMIT, claimBoth, formatToken, poolKeyOf, readPair, swap} from "../pool.js";
import {clear, code, el, field, input, row, status} from "../ui.js";

const HOOK_ABI = [
  {
    type: "function",
    name: "commitmentHash",
    stateMutability: "pure",
    inputs: [
      {name: "id", type: "bytes32"},
      {name: "zeroForOne", type: "bool"},
      {name: "amountSpecified", type: "int256"},
      {name: "sqrtPriceLimitX96", type: "uint160"},
      {name: "salt", type: "bytes32"},
    ],
    outputs: [{type: "bytes32"}],
  },
  {
    type: "function",
    name: "commit",
    stateMutability: "payable",
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
      {name: "commitment", type: "bytes32"},
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "sweepExpired",
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
      {name: "commitment", type: "bytes32"},
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "configOf",
    stateMutability: "view",
    inputs: [{type: "bytes32"}],
    outputs: [
      {name: "delayBlocks", type: "uint32"},
      {name: "ttlBlocks", type: "uint32"},
      {name: "bond", type: "uint128"},
    ],
  },
  {
    type: "function",
    name: "commitmentOf",
    stateMutability: "view",
    inputs: [{type: "bytes32"}],
    outputs: [
      {name: "owner", type: "address"},
      {name: "madeAt", type: "uint64"},
      {name: "bond", type: "uint128"},
    ],
  },
  {
    type: "function",
    name: "forfeited",
    stateMutability: "view",
    inputs: [{type: "bytes32"}],
    outputs: [{type: "uint256"}],
  },
];

/** A cryptographically random 32-byte salt, hex-encoded. */
function newSalt() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

/**
 * Where a browser keeps its salts.
 *
 * Scoped to the hook and the account, so two wallets on one machine do not see each other's pending orders and a
 * different deployment does not resurrect stale ones.
 */
function storeKey(deployment, account) {
  return `hookforge:commit:${deployment.chainId}:${deployment.hook}:${(account ?? "anon").toLowerCase()}`;
}

function load(deployment, account) {
  try {
    return JSON.parse(localStorage.getItem(storeKey(deployment, account)) ?? "[]");
  } catch {
    return [];
  }
}

function save(deployment, account, orders) {
  try {
    localStorage.setItem(storeKey(deployment, account), JSON.stringify(orders));
  } catch {
    // A browser with storage disabled still works for a single session; the orders just live in memory.
  }
}

export function mountCommit(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {
    config: null,
    pair: null,
    block: 0n,
    forfeited: 0n,
    orders: [],
    amount: demo.defaultAmount ?? "0.01",
    zeroForOne: true,
  };

  const feed = status();
  const readout = el("div", {class: "kv"});
  const form = el("div", {class: "panel__form"});
  const actions = el("div", {class: "panel__actions"});
  const orderList = el("ul", {class: "attempts"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "Commit now, trade later"}),
      el("p", {
        class: "panel__lede",
        text:
          demo.lede ??
          "Every swap here must have been committed to in an earlier block, so nobody can react to an order they can see.",
      }),
    ]),
    readout,
    form,
    actions,
    feed.node,
    el("h4", {class: "panel__subhead", text: "Your commitments"}),
    orderList,
  );

  const amountInput = input({type: "number", min: "0", step: "0.001", value: state.amount});
  amountInput.addEventListener("input", () => {
    state.amount = amountInput.value;
  });

  const directionSelect = el("select", {class: "input"}, [
    el("option", {value: "0", text: demo.zeroForOneLabel ?? "Sell currency0"}),
    el("option", {value: "1", text: demo.oneForZeroLabel ?? "Buy currency0"}),
  ]);
  directionSelect.addEventListener("change", () => {
    state.zeroForOne = directionSelect.value === "0";
  });

  form.append(
    field({label: "Size", hint: "The amount you are committing to trade. A commitment is good for exactly this size.", input: amountInput}),
    field({label: "Direction", hint: "And for exactly this direction.", input: directionSelect}),
  );

  /** Parses the size box into base units of whichever token is being spent. */
  function amountUnits() {
    const decimals = state.pair ? (state.zeroForOne ? state.pair.decimals0 : state.pair.decimals1) : 18;
    const [whole = "0", fraction = ""] = String(state.amount || "0").split(".");
    const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
    return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
  }

  async function refresh() {
    const {publicClient} = clients;
    const read = (functionName, args) =>
      publicClient.readContract({address: deployment.hook, abi: HOOK_ABI, functionName, args});

    const [config, forfeited, block] = await Promise.all([
      read("configOf", [deployment.poolId]).catch(() => null),
      read("forfeited", [deployment.poolId]).catch(() => 0n),
      publicClient.getBlockNumber(),
    ]);

    state.config = config;
    state.forfeited = forfeited ?? 0n;
    state.block = block;
    state.pair = await readPair(publicClient, deployment, session.account);
    state.orders = load(deployment, session.account);

    // A commitment the chain no longer holds has been spent or swept, so it is dropped from the local list rather
    // than left there implying a trade the pool would refuse.
    const live = [];
    for (const order of state.orders) {
      const [owner] = await read("commitmentOf", [order.hash]).catch(() => [null]);
      if (owner && owner !== "0x0000000000000000000000000000000000000000") live.push(order);
    }
    if (live.length !== state.orders.length) {
      state.orders = live;
      save(deployment, session.account, live);
    }

    render();
  }

  function bondText() {
    if (!state.config) return "not available";
    const bond = state.config[2] ?? 0n;
    return bond === 0n ? "none" : `${formatToken(bond, 18, 4)} ${deployment.nativeSymbol ?? "ETH"}`;
  }

  function render() {
    clear(readout).append(
      row("Delay before a commitment may be revealed", state.config ? `${state.config[0]} blocks` : "not available"),
      row("Commitment expires after", state.config ? `${state.config[1]} blocks` : "not available"),
      row("Bond per commitment", bondText()),
      row("Bonds forfeited to this pool", `${formatToken(state.forfeited, 18, 4)} ${deployment.nativeSymbol ?? "ETH"}`),
      row("Current block", state.block.toString()),
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
      renderOrders();
      return;
    }

    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: "Commit to this trade", onclick: makeCommitment}),
      el("button", {
        class: "btn",
        type: "button",
        text: "Try to swap without committing",
        title: "This is what an attacker reacting to your order would have to do, and the pool refuses it.",
        onclick: swapUncommitted,
      }),
      deployment.faucet ? el("button", {class: "btn", type: "button", text: "Get test tokens", onclick: claim}) : null,
    );
    renderOrders();
  }

  function renderOrders() {
    clear(orderList);
    if (!state.orders.length) {
      orderList.append(
        el("li", {
          class: "attempt attempt--idle",
          text: session.account
            ? "No standing commitments. Commit to a trade and it appears here with the block it becomes revealable."
            : "Connect a wallet to see your commitments.",
        }),
      );
      return;
    }

    for (const order of state.orders) {
      const revealableAt = BigInt(order.revealableAt);
      const expiresAt = BigInt(order.expiresAt);
      const ready = state.block >= revealableAt;
      const expired = state.block > expiresAt;
      const label = expired
        ? "expired"
        : ready
          ? "revealable"
          : `${(revealableAt - state.block).toString()} block(s) to go`;

      orderList.append(
        el("li", {class: `attempt attempt--${expired ? "refused" : ready ? "ok" : "idle"}`}, [
          el("span", {class: "attempt__badge", text: label}),
          el("span", {class: "attempt__detail"}, [
            el("span", {
              text: `${order.zeroForOne ? demo.zeroForOneLabel ?? "sell currency0" : demo.oneForZeroLabel ?? "buy currency0"}, ${order.display}`,
            }),
            code(`${order.hash.slice(0, 18)}…`),
          ]),
          expired
            ? el("button", {class: "btn btn--small", type: "button", text: "Sweep the bond", onclick: () => sweep(order)})
            : el("button", {
                class: "btn btn--small btn--primary",
                type: "button",
                text: "Reveal and swap",
                disabled: ready ? null : "disabled",
                onclick: () => reveal(order),
              }),
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

  async function makeCommitment() {
    try {
      const amount = amountUnits();
      if (amount <= 0n) {
        feed.set("error", "Enter a size above zero.");
        return;
      }

      const salt = newSalt();
      const zeroForOne = state.zeroForOne;
      const limit = zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT;

      // The hash is computed by the contract rather than in the browser, so the encoding can never drift from what
      // the hook will recompute at reveal time. A mismatch there would burn the bond for no reason.
      feed.set("pending", "Hashing the order…");
      const hash = await clients.publicClient.readContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "commitmentHash",
        args: [deployment.poolId, zeroForOne, -amount, limit, salt],
      });

      feed.set("pending", "Sending the commitment. It reveals nothing about your order.");
      const bond = state.config ? state.config[2] : 0n;
      const txHash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "commit",
        args: [poolKeyOf(deployment), hash],
        value: bond,
        account: session.account,
      });
      const receipt = await clients.publicClient.waitForTransactionReceipt({hash: txHash});
      if (receipt.status !== "success") throw new Error("The commitment transaction reverted.");

      const decimals = state.pair ? (zeroForOne ? state.pair.decimals0 : state.pair.decimals1) : 18;
      const symbol = state.pair ? (zeroForOne ? state.pair.symbol0 : state.pair.symbol1) : "";
      const made = receipt.blockNumber;
      const orders = [
        {
          hash,
          salt,
          zeroForOne,
          amount: amount.toString(),
          display: `${formatToken(amount, decimals, 4)} ${symbol}`.trim(),
          madeAt: made.toString(),
          revealableAt: (made + BigInt(state.config ? state.config[0] : 1)).toString(),
          expiresAt: (made + BigInt(state.config ? state.config[1] : 50)).toString(),
        },
        ...load(deployment, session.account),
      ];
      save(deployment, session.account, orders);

      const link = explorerFor(deployment.chainId, "tx", txHash);
      feed.set(
        "ok",
        `Committed. The salt stays in this browser until you reveal. Revealable at block ${orders[0].revealableAt}.`,
        link ? {href: link, text: "View"} : null,
      );
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function reveal(order) {
    try {
      feed.set("pending", "Revealing. The swap must match the commitment exactly.");
      const hash = await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: order.zeroForOne,
        amount: BigInt(order.amount),
        // The salt is the reveal. Encoded as a bare bytes32, which is what the hook decodes from hookData.
        hookData: order.salt,
      });
      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Revealed and swapped. The bond came back with it.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
      await refresh();
    }
  }

  async function sweep(order) {
    try {
      feed.set("pending", "Forfeiting the expired bond to the pool…");
      const txHash = await clients.walletClient.writeContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "sweepExpired",
        args: [poolKeyOf(deployment), order.hash],
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash: txHash});
      feed.set("ok", "Swept. An abandoned option is paid for by whoever wrote it.");
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  async function swapUncommitted() {
    try {
      feed.set("pending", "Sending a swap with no commitment behind it…");
      await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: state.zeroForOne,
        amount: amountUnits(),
        hookData: newSalt(),
      });
      feed.set("error", "That went through, which it should not have. The pool is not configured for this hook.");
    } catch (error) {
      // The refusal is the mechanism working, so it is reported as the demonstration it is.
      feed.set("ok", `Refused, which is the point: ${readableError(error, deployment.errors ?? [])}`);
    }
    await refresh();
  }

  const onError = (error) => feed.set("error", readableError(error, deployment.errors ?? []));
  refresh().catch(onError);
  session.onChange(() => refresh().catch(onError));

  // The countdown is measured in blocks, so it has to advance with them rather than on a wall clock.
  clients.publicClient
    .watchBlockNumber({
      emitOnBegin: false,
      onBlockNumber: (block) => {
        state.block = block;
        render();
      },
    })
    ?.catch?.(() => {});

  return {refresh};
}
