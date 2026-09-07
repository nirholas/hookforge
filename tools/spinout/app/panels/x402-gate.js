/**
 * The x402 gate demo: read the pool's 402 challenge, pay it, and watch the fee change on the same swap.
 *
 * This is the whole product in one panel. A visitor connects, sees the price the pool is asking, signs an EIP-3009
 * authorization in a modal, and swaps with it attached. The panel then runs the same swap without a payment so the
 * two fills sit side by side, because the claim the hook makes is comparative and a single number does not
 * demonstrate it.
 */
import {formatUnits, parseUnits} from "viem";

import {chainName, explorerFor, formatAmount, readableError, shortAddress} from "../wallet.js";
import {asChallenge, readAsset, resolveDomain, signPayment} from "../x402.js";
import {clear, code, el, field, input, modal, row, status} from "../ui.js";

const HOOK_ABI = [
  {
    type: "function",
    name: "quote",
    stateMutability: "view",
    inputs: [{name: "id", type: "bytes32"}],
    outputs: [
      {
        type: "tuple",
        components: [
          {name: "scheme", type: "string"},
          {name: "network", type: "uint256"},
          {name: "maxAmountRequired", type: "uint256"},
          {name: "asset", type: "address"},
          {name: "payTo", type: "address"},
          {name: "resource", type: "string"},
          {name: "maxTimeoutSeconds", type: "uint256"},
        ],
      },
    ],
  },
  {
    type: "function",
    name: "feeTiers",
    stateMutability: "view",
    inputs: [{name: "id", type: "bytes32"}],
    outputs: [{name: "baseFee", type: "uint24"}, {name: "discountedFee", type: "uint24"}],
  },
  {
    type: "function",
    name: "collected",
    stateMutability: "view",
    inputs: [{type: "bytes32"}],
    outputs: [{type: "uint256"}],
  },
  {type: "function", name: "withdraw", stateMutability: "nonpayable", inputs: [{type: "bytes32"}], outputs: []},
];

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
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{type: "address"}],
    outputs: [{type: "uint256"}],
  },
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

/** Formats a v4 LP fee, which is in hundredths of a bip, as the percentage a person expects to see. */
function feeText(pips) {
  return `${(Number(pips) / 10_000).toFixed(4).replace(/0+$/, "").replace(/\.$/, "")}%`;
}

export function mountX402Gate(root, context) {
  const {deployment, clients, session} = context;
  const state = {requirements: null, tiers: null, asset: null, domain: null, results: []};

  const feed = status();
  const challengePane = el("div");
  const comparisonPane = el("div", {class: "compare"});
  const actions = el("div", {class: "panel__actions"});

  root.append(
    el("div", {class: "panel__head"}, [
      el("h3", {text: "Pay for a cheaper fee"}),
      el("p", {
        class: "panel__lede",
        text:
          "The pool posts a price on-chain. Pay it and the same swap costs less. Nothing is curated and no server " +
          "has to be up.",
      }),
    ]),
    challengePane,
    actions,
    feed.node,
    comparisonPane,
  );

  /** Reads everything the panel shows, so one call refreshes the whole view. */
  async function refresh() {
    const {publicClient} = clients;
    const [requirements, tiers] = await Promise.all([
      publicClient.readContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "quote",
        args: [deployment.poolId],
      }),
      publicClient.readContract({
        address: deployment.hook,
        abi: HOOK_ABI,
        functionName: "feeTiers",
        args: [deployment.poolId],
      }),
    ]);

    state.requirements = requirements;
    state.tiers = {baseFee: tiers[0], discountedFee: tiers[1]};
    state.asset = await readAsset(publicClient, requirements.asset, session.account);
    state.domain = await resolveDomain(publicClient, requirements.asset, deployment.chainId);

    renderChallenge();
    renderActions();
  }

  function renderChallenge() {
    const {requirements, tiers, asset} = state;
    const price = formatUnits(requirements.maxAmountRequired, asset.decimals);

    clear(challengePane).append(
      el("div", {class: "kv"}, [
        row("Price", `${price} ${asset.symbol}`),
        row("Asset", shortAddress(requirements.asset)),
        row("Paid to", shortAddress(requirements.payTo)),
        row("Fee without paying", feeText(tiers.baseFee)),
        row("Fee after paying", feeText(tiers.discountedFee)),
        row("Authorization valid for", `${requirements.maxTimeoutSeconds}s`),
        row("Token EIP-712 domain", state.domain.verified ? `verified (${state.domain.how})` : `UNVERIFIED (${state.domain.how})`),
      ]),
      el("details", {class: "raw"}, [
        el("summary", {text: "The same thing as an HTTP 402 body"}),
        code(JSON.stringify(asChallenge(requirements, `${location.origin}/`), null, 2)),
      ]),
    );
  }

  function renderActions() {
    clear(actions);
    if (!session.account) {
      actions.append(el("button", {class: "btn btn--primary", type: "button", text: "Connect wallet", onclick: session.connect}));
      return;
    }

    const balanceText = `${formatAmount(state.asset.balance, state.asset.decimals, 2)} ${state.asset.symbol}`;
    actions.append(
      el("button", {class: "btn btn--primary", type: "button", text: "Pay and swap", onclick: openPaymentModal}),
      el("button", {class: "btn", type: "button", text: "Swap without paying", onclick: () => runSwap(null)}),
      deployment.faucet
        ? el("button", {class: "btn", type: "button", text: `Get test ${state.asset.symbol}`, onclick: claimAsset})
        : null,
      el("span", {class: "panel__balance", text: `Balance: ${balanceText}`}),
    );
  }

  async function claimAsset() {
    try {
      feed.set("pending", `Minting test ${state.asset.symbol}…`);
      const hash = await clients.walletClient.writeContract({
        address: state.requirements.asset,
        abi: ERC20_ABI,
        functionName: "claim",
        account: session.account,
      });
      await clients.publicClient.waitForTransactionReceipt({hash});
      await refresh();
      feed.set("ok", `Minted. You can pay the pool's price now.`);
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  /** The payment modal: what is being signed, in full, before it is signed. */
  function openPaymentModal() {
    const {requirements, asset, domain} = state;
    const price = formatUnits(requirements.maxAmountRequired, asset.decimals);
    const amountInput = input({type: "text", value: price, inputmode: "decimal", "aria-label": "Amount to authorise"});

    const short = asset.balance < requirements.maxAmountRequired;
    const payButton = el("button", {
      class: "btn btn--primary",
      type: "button",
      text: short ? `Not enough ${asset.symbol}` : "Sign authorization",
      disabled: short,
    });

    const dialog = modal({
      title: "Authorise an x402 payment",
      body: [
        el("p", {
          class: "modal__lede",
          text:
            "You are signing an EIP-3009 authorization, not sending a transaction. Nothing moves until the swap " +
            "runs, and if the swap reverts for any reason the payment reverts with it. That atomicity is what x402 " +
            "over HTTP cannot give you.",
        }),
        el("div", {class: "kv"}, [
          row("Paying", `${price} ${asset.symbol}`),
          // The payee is the hook, and that is the security property rather than an implementation detail:
          // receiveWithAuthorization refuses any submitter that is not the named payee, so an authorization made
          // out to the hook cannot be lifted and spent anywhere else.
          row("Payable only to", `${shortAddress(requirements.payTo)} (the hook)`),
          row("Valid for", `${requirements.maxTimeoutSeconds} seconds`),
          row("Token domain", domain.verified ? `verified (${domain.how})` : "NOT verified"),
        ]),
        field({
          label: "Amount to authorise",
          hint: `The pool requires at least ${price} ${asset.symbol}. Authorising more is allowed and is not refunded.`,
          input: amountInput,
        }),
        !domain.verified
          ? el("p", {
              class: "warn",
              text:
                "This token does not publish an EIP-712 domain that can be checked, so the signature may be rejected " +
                "on-chain. Nothing will be lost if it is.",
            })
          : null,
      ],
      actions: [
        el("button", {class: "btn", type: "button", text: "Cancel", onclick: () => dialog.close()}),
        payButton,
      ],
    });

    payButton.addEventListener("click", async () => {
      let value;
      try {
        value = parseUnits(amountInput.value.trim() || price, asset.decimals);
      } catch {
        feed.set("error", "That amount is not a number.");
        return;
      }
      if (value < requirements.maxAmountRequired) {
        feed.set("error", `The pool requires at least ${price} ${asset.symbol}.`);
        return;
      }

      dialog.close();
      try {
        feed.set("pending", "Waiting for your signature…");
        const {hookData} = await signPayment(clients.walletClient, {
          domain: domain.domain,
          from: session.account,
          to: deployment.hook,
          value,
          timeoutSeconds: Number(requirements.maxTimeoutSeconds),
        });
        await runSwap(hookData);
      } catch (error) {
        feed.set("error", readableError(error, deployment.errors ?? []));
      }
    });
  }

  /** Runs the swap, with or without a payment attached, and records the fill so the two can be compared. */
  async function runSwap(hookData) {
    const {publicClient, walletClient} = clients;
    const paid = Boolean(hookData);

    try {
      const amount = deployment.demoSwapAmount ?? 10n ** 16n;
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

      feed.set("pending", paid ? "Swapping with your payment attached…" : "Swapping with no payment…");
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
          hookData ?? "0x",
        ],
        account: session.account,
      });

      const receipt = await publicClient.waitForTransactionReceipt({hash});
      // A wallet client does not throw on a reverted transaction, so the status has to be read or a refusal is
      // reported as a success.
      if (receipt.status !== "success") throw new Error("The swap reverted on-chain.");
      const link = explorerFor(deployment.chainId, "tx", hash);
      feed.set("ok", paid ? "Paid and swapped." : "Swapped at the undiscounted fee.", link ? {href: link, text: "View"} : null);

      state.results.push({paid, hash, gasUsed: receipt.gasUsed});
      renderComparison();
      await refresh();
    } catch (error) {
      feed.set("error", readableError(error, deployment.errors ?? []));
    }
  }

  function renderComparison() {
    const paid = state.results.filter((r) => r.paid).at(-1);
    const unpaid = state.results.filter((r) => !r.paid).at(-1);
    clear(comparisonPane);
    if (!paid || !unpaid) {
      comparisonPane.append(
        el("p", {
          class: "compare__hint",
          text: "Run both swaps to see them side by side. That comparison is the claim this hook makes.",
        }),
      );
      return;
    }

    comparisonPane.append(
      el("div", {class: "compare__grid"}, [
        el("div", {class: "compare__cell"}, [
          el("span", {class: "compare__label", text: "Without paying"}),
          el("span", {class: "compare__value", text: feeText(state.tiers.baseFee)}),
        ]),
        el("div", {class: "compare__cell compare__cell--win"}, [
          el("span", {class: "compare__label", text: "After paying"}),
          el("span", {class: "compare__value", text: feeText(state.tiers.discountedFee)}),
        ]),
      ]),
    );
  }

  refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? [])));
  session.onChange(() => refresh().catch((error) => feed.set("error", readableError(error, deployment.errors ?? []))));

  return {refresh};
}
