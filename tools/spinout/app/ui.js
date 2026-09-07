/**
 * The small amount of DOM machinery the demos need. No framework: a page with one panel on it does not need a
 * reconciler, and a dependency-free demo is one fewer thing between a visitor and the button.
 */

export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "html") node.innerHTML = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of [].concat(children)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
  return node;
}

/**
 * A modal that traps focus and closes on Escape.
 *
 * Worth doing properly rather than reaching for a `<dialog>` polyfill: this one holds a payment authorization the
 * visitor is about to sign, and a dialog somebody can tab out of behind is a dialog they can sign without reading.
 */
export function modal({title, body, actions, onClose}) {
  const previouslyFocused = document.activeElement;

  const close = () => {
    document.removeEventListener("keydown", onKey);
    overlay.remove();
    previouslyFocused?.focus?.();
    onClose?.();
  };

  const onKey = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close();
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = [...panel.querySelectorAll("button, [href], input, select, textarea, [tabindex]")].filter(
      (node) => !node.disabled && node.offsetParent !== null,
    );
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  const panel = el("div", {class: "modal__panel", role: "dialog", "aria-modal": "true", "aria-label": title}, [
    el("div", {class: "modal__head"}, [
      el("h3", {text: title}),
      el("button", {class: "modal__close", type: "button", "aria-label": "Close", onclick: close, text: "×"}),
    ]),
    el("div", {class: "modal__body"}, body),
    el("div", {class: "modal__actions"}, actions),
  ]);

  const overlay = el("div", {class: "modal", onclick: (event) => event.target === overlay && close()}, [panel]);
  document.body.append(overlay);
  document.addEventListener("keydown", onKey);
  panel.querySelector("button:not(.modal__close), input")?.focus();

  return {close, panel};
}

/** A labelled field. `hint` is where units go, because a number field with no units is a support ticket. */
export function field({label, hint, input}) {
  return el("label", {class: "field"}, [
    el("span", {class: "field__label", text: label}),
    input,
    hint ? el("span", {class: "field__hint", text: hint}) : null,
  ]);
}

export function input(attrs = {}) {
  return el("input", {class: "input", ...attrs});
}

/** A live region for progress, so a screen reader hears what a sighted visitor watches. */
export function status() {
  const node = el("p", {class: "status", role: "status", "aria-live": "polite"});
  return {
    node,
    set(state, message, link) {
      node.className = `status status--${state}`;
      clear(node);
      node.append(el("span", {class: "status__dot"}), el("span", {text: message}));
      if (link) node.append(" ", el("a", {href: link.href, target: "_blank", rel: "noopener", text: link.text}));
    },
    clear() {
      node.className = "status";
      clear(node);
    },
  };
}

/** A key/value row, for the many small facts these panels display. */
export function row(key, value, mono = true) {
  return el("div", {class: "kv__row"}, [
    el("span", {class: "kv__key", text: key}),
    el("span", {class: mono ? "kv__value kv__value--mono" : "kv__value", text: value}),
  ]);
}

export function code(text) {
  return el("pre", {class: "code"}, [el("code", {text})]);
}
