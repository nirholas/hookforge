/**
 * The demo entry point.
 *
 * Mounts the panel for whichever hook this site is for, against whichever chain the visitor is on. The page it lands
 * in is already complete without it: everything here adds is the ability to press the buttons.
 */
import {chainName, connect, formatAmount, provider, publicClientFor, readableError, shortAddress, walletClientFor, watch} from "./wallet.js";
import {clear, el} from "./ui.js";
import {mountX402Gate} from "./panels/x402-gate.js";
import {mountFeeHook} from "./panels/fee-hook.js";


/** Whether a deployment points at an RPC only reachable from the machine running the chain. */
function isLocalOnly(deployment) {
  const url = deployment?.rpcUrl ?? "";
  return /(^|\/\/)(127\.0\.0\.1|localhost|0\.0\.0\.0|\[::1\])/.test(url);
}

/** Whether the connected wallet reports being on `chainId`, which is what makes a local chain usable. */
function walletIsOnChain(chainId) {
  return Boolean(provider()) && Number.isInteger(chainId);
}

/** Panels by kind. A hook names its kind in the demo config rather than the entry point knowing every slug. */
const PANELS = {
  "x402-gate": mountX402Gate,
  fee: mountFeeHook,
};

const root = document.querySelector("[data-demo]");
if (root) start(root).catch((error) => fail(root, readableError(error)));

function fail(node, message) {
  clear(node).append(el("div", {class: "panel panel--empty"}, [el("p", {text: message})]));
}

async function start(node) {
  const config = JSON.parse(document.getElementById("deployments")?.textContent ?? "{}");
  const mount = PANELS[config.demo?.panel ?? node.dataset.demo];
  if (!mount) return fail(node, "No demo panel is configured for this hook yet.");

  const session = {
    account: null,
    chainId: null,
    listeners: [],
    onChange(fn) {
      this.listeners.push(fn);
    },
    notify() {
      for (const fn of this.listeners) fn(this);
    },
    async connect() {
      const result = await connect();
      if (result.error) {
        header.querySelector("[data-connect-error]").textContent = result.error;
        return;
      }
      session.account = result.account;
      session.chainId = result.chainId;
      render();
    },
  };

  const header = el("div", {class: "panel__wallet"});
  const body = el("div", {class: "panel__body"});
  clear(node).append(el("div", {class: "panel"}, [header, body]));

  watch((change) => {
    Object.assign(session, change);
    render();
  });

  // A read-only view before anybody connects: the challenge and the terms are public, so show them.
  if (!session.chainId) {
    const injected = provider();
    if (injected) {
      try {
        session.chainId = Number(await injected.request({method: "eth_chainId"}));
        const accounts = await injected.request({method: "eth_accounts"});
        session.account = accounts?.[0] ?? null;
      } catch {
        // A wallet that will not answer without a prompt is fine; the visitor can press connect.
      }
    }
  }
  // Only fall back to the configured default when it is somewhere a browser can actually reach. A local chain is
  // usable when the visitor's own wallet is on it and never otherwise: a page served over https that tries to fetch
  // a loopback RPC is blocked by the browser, and the visitor sees a network error for a demo that was never going
  // to work from there.
  if (!session.chainId && config.defaultChainId && !isLocalOnly(config.chains?.[String(config.defaultChainId)])) {
    session.chainId = config.defaultChainId;
  }

  render();

  function render() {
    renderHeader();
    const candidate = session.chainId ? config.chains?.[String(session.chainId)] : null;
    // A local deployment is only offered when the wallet is genuinely on that chain, which is the one case where
    // the loopback RPC is reachable.
    const deployment = candidate && isLocalOnly(candidate) && !walletIsOnChain(session.chainId) ? null : candidate;

    if (!deployment) {
      clear(body).append(
        el("div", {class: "panel--empty"}, [
          el("p", {
            text: session.chainId
              ? `This hook is not deployed on ${chainName(session.chainId)} yet.`
              : "Connect a wallet on a chain this hook is deployed to, or run the whole thing locally.",
          }),
          el("p", {class: "panel__hint"}, [
            "Every chain it is deployed on is listed below. To try it with no wallet and no funds, run ",
            el("code", {text: "anvil"}),
            " and the deploy script in the repository: the whole stack comes up in one command.",
          ]),
          config.chains && Object.keys(config.chains).length
            ? el("p", {
                class: "panel__hint",
                text: `Deployed on: ${Object.keys(config.chains).map((id) => chainName(Number(id))).join(", ")}.`,
              })
            : null,
        ]),
      );
      return;
    }

    const publicClient = publicClientFor(session.chainId, deployment.rpcUrl);
    const walletClient = session.account ? walletClientFor(session.chainId, session.account) : null;

    clear(body);
    mount(body, {
      deployment: {...deployment, chainId: session.chainId, demo: config.demo},
      clients: {publicClient, walletClient},
      session,
    });
  }

  function renderHeader() {
    clear(header).append(
      el("span", {class: "panel__chain", text: session.chainId ? chainName(session.chainId) : "No network"}),
      session.account
        ? el("span", {class: "panel__account", text: shortAddress(session.account)})
        : el("button", {class: "btn btn--small", type: "button", text: "Connect", onclick: () => session.connect()}),
      el("span", {class: "panel__error", "data-connect-error": true}),
    );
  }
}
