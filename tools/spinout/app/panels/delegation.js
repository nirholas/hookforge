/**
 * The demo for AgentBudget: sign a spending limit for an agent, then watch the pool enforce it.
 *
 * Two signatures, which is the mechanism rather than an inconvenience. The principal signs a delegation once,
 * naming the agent and the cap; the agent signs each swap it makes under that delegation. The pool checks both and
 * refuses anything past the cap, so the limit lives in the venue rather than in the agent's own code.
 *
 * The panel signs both from the connected account, which is not how it would run in production (an agent would hold
 * its own key) but is the only way to demonstrate the whole flow in a browser without asking somebody to manage two
 * wallets. The page says so rather than implying otherwise.
 */
import {encodeAbiParameters, keccak256, parseAbiParameters, toHex} from "viem";

import {explorerFor, readableError, shortAddress} from "../wallet.js";
import {formatToken, readPair, swap} from "../pool.js";
import {clear, code, el, field, input, modal, row, status} from "../ui.js";

const HOOK_ABI = [
  {
    type: "function",
    name: "remainingBudget",
    stateMutability: "view",
    inputs: [
      {
        type: "tuple",
        components: [
          {name: "principal", type: "address"},
          {name: "agent", type: "address"},
          {name: "poolId", type: "bytes32"},
          {name: "cap0", type: "uint128"},
          {name: "cap1", type: "uint128"},
          {name: "epochLength", type: "uint32"},
          {name: "expiry", type: "uint64"},
          {name: "salt", type: "bytes32"},
        ],
      },
    ],
    outputs: [{type: "uint256"}, {type: "uint256"}],
  },
  {
    type: "function",
    name: "hashDelegation",
    stateMutability: "pure",
    inputs: [
      {
        type: "tuple",
        components: [
          {name: "principal", type: "address"},
          {name: "agent", type: "address"},
          {name: "poolId", type: "bytes32"},
          {name: "cap0", type: "uint128"},
          {name: "cap1", type: "uint128"},
          {name: "epochLength", type: "uint32"},
          {name: "expiry", type: "uint64"},
          {name: "salt", type: "bytes32"},
        ],
      },
    ],
    outputs: [{type: "bytes32"}],
  },
];

const DELEGATION_TYPES = {
  Delegation: [
    {name: "principal", type: "address"},
    {name: "agent", type: "address"},
    {name: "poolId", type: "bytes32"},
    {name: "cap0", type: "uint128"},
    {name: "cap1", type: "uint128"},
    {name: "epochLength", type: "uint32"},
    {name: "expiry", type: "uint64"},
    {name: "salt", type: "bytes32"},
  ],
};

const SWAP_TYPES = {
  SwapAuthorization: [
    {name: "delegationHash", type: "bytes32"},
    {name: "nonce", type: "uint256"},
    {name: "deadline", type: "uint64"},
  ],
};

function domainFor(deployment) {
  return {
    name: "HookForgeAgentBudget",
    version: "1",
    chainId: deployment.chainId,
    verifyingContract: deployment.hook,
  };
}

function freshBytes32() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

export function mountDelegation(root, context) {
  const {deployment, clients, session} = context;
  const demo = deployment.demo ?? {};
  const state = {delegation: null, signature: null, nonce: 0n, pair: null, remaining: null};

  const feed = status();
  const readout = el("div", {class: "kv"});
  const actions = el("div", {class: "panel__actions"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: demo.title ?? "A spending limit the pool enforces"}),
      el("p", {
        class: "panel__lede",
        text:
          demo.lede ??
          "Sign a budget for an agent, then trade under it. The pool refuses the swap that would go past the cap.",
      }),
    ]),
    readout,
    actions,
    feed.node,
  );

  async function refresh() {
    state.pair = await readPair(clients.publicClient, deployment, session.account);
    if (state.delegation) {
      try {
        state.remaining = await clients.publicClient.readContract({
          address: deployment.hook,
          abi: HOOK_ABI,
          functionName: "remainingBudget",
          args: [state.delegation],
        });
      } catch {
        state.remaining = null;
      }
    }
    render();
  }

  function render() {
    const {pair} = state;
    clear(readout).append(
      row("Pool", shortAddress(deployment.hook)),
      state.delegation ? row("Agent", shortAddress(state.delegation.agent)) : null,
      state.delegation
        ? row("Cap per epoch", `${formatToken(state.delegation.cap0, pair.decimals0, 3)} ${pair.symbol0}`)
        : row("Delegation", "none signed yet"),
      state.remaining
        ? row("Left this epoch", `${formatToken(state.remaining[0], pair.decimals0, 3)} ${pair.symbol0}`)
        : null,
    );

    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }
    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: "Sign a budget", onclick: openDelegationModal}),
      state.delegation
        ? el("button", {class: "btn", type: "button", text: "Swap under it", onclick: swapUnderDelegation})
        : null,
    );
  }

  function openDelegationModal() {
    const {pair} = state;
    const cap = input({type: "text", value: "0.05", inputmode: "decimal", "aria-label": "Cap per epoch"});
    const epoch = input({type: "text", value: "3600", inputmode: "numeric", "aria-label": "Epoch length in seconds"});
    const signButton = el("button", {class: "btn btn--primary", type: "button", text: "Sign the delegation"});

    const dialog = modal({
      title: "Authorise an agent to trade this pool",
      body: [
        el("p", {
          class: "modal__lede",
          text:
            "You are signing a standing authorisation, not a transaction. It names one agent, one pool and a cap per " +
            "epoch, and the pool refuses any swap that would exceed it.",
        }),
        el("div", {class: "kv"}, [
          row("Agent", `${shortAddress(session.account)} (you, for this demo)`),
          row("Pool", shortAddress(deployment.hook)),
        ]),
        field({label: `Cap per epoch, in ${pair.symbol0}`, input: cap}),
        field({label: "Epoch length, seconds", hint: "Budgets reset on the boundary and do not roll over.", input: epoch}),
        el("p", {
          class: "warn",
          text:
            "In production the agent holds its own key and signs each swap itself. This demo signs both halves from " +
            "your account so the whole flow can be shown in one browser.",
        }),
      ],
      actions: [
        el("button", {class: "btn", type: "button", text: "Cancel", onclick: () => dialog.close()}),
        signButton,
      ],
    });

    signButton.addEventListener("click", async () => {
      dialog.close();
      try {
        const decimals = state.pair.decimals0;
        const capValue = BigInt(Math.round(Number(cap.value || "0") * 10 ** Number(decimals)));

        const delegation = {
          principal: session.account,
          agent: session.account,
          poolId: deployment.poolId,
          cap0: capValue,
          cap1: capValue,
          epochLength: Number(epoch.value || "3600"),
          expiry: BigInt(Math.floor(Date.now() / 1000) + 30 * 86400),
          salt: freshBytes32(),
        };

        feed.set("pending", "Waiting for your signature…");
        const signature = await clients.walletClient.signTypedData({
          account: session.account,
          domain: domainFor(deployment),
          types: DELEGATION_TYPES,
          primaryType: "Delegation",
          message: delegation,
        });

        state.delegation = delegation;
        state.signature = signature;
        state.nonce = 0n;
        feed.set("ok", "Signed. The pool will now hold that agent to this budget.");
        await refresh();
      } catch (error) {
        feed.set("error", readableError(error, deployment.errors ?? []));
      }
    });
  }

  async function swapUnderDelegation() {
    try {
      const delegationHash = await clients.publicClient.readContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "hashDelegation",
        args: [state.delegation],
      });

      state.nonce += 1n;
      const authorization = {
        delegationHash,
        nonce: state.nonce,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
      };

      feed.set("pending", "Signing this swap as the agent…");
      const agentSignature = await clients.walletClient.signTypedData({
        account: session.account,
        domain: domainFor(deployment),
        types: SWAP_TYPES,
        primaryType: "SwapAuthorization",
        message: authorization,
      });

      const hookData = encodeAbiParameters(
        parseAbiParameters(
          "(address,address,bytes32,uint128,uint128,uint32,uint64,bytes32), bytes, (bytes32,uint256,uint64), bytes",
        ),
        [
          [
            state.delegation.principal,
            state.delegation.agent,
            state.delegation.poolId,
            state.delegation.cap0,
            state.delegation.cap1,
            state.delegation.epochLength,
            state.delegation.expiry,
            state.delegation.salt,
          ],
          state.signature,
          [authorization.delegationHash, authorization.nonce, authorization.deadline],
          agentSignature,
        ],
      );

      feed.set("pending", "Swapping under the budget…");
      const hash = await swap({
        ...clients,
        account: session.account,
        deployment,
        zeroForOne: true,
        amount: BigInt(deployment.demoSwapAmount ?? "10000000000000000"),
        hookData,
      });

      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", "Swapped inside the budget.", link ? {href: link, text: "View"} : null);
      await refresh();
    } catch (error) {
      // Going past the cap is the mechanism working, so it is reported as an outcome.
      feed.set("ok", `The pool refused it: ${readableError(error, deployment.errors ?? [])}`);
      await refresh();
    }
  }

  refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? [])));
  session.onChange(() => refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? []))));
  return {refresh};
}
