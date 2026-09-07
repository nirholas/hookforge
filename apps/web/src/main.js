/**
 * Client entry for hookforge.pages.dev.
 *
 * Every page is server-rendered HTML generated from the hook registry, so this file only adds behaviour that needs a
 * browser: the three.js lifecycle scenes, catalogue filtering, and copy buttons. If it fails to load, the catalogue is
 * still complete, every link still resolves, and every hook page still reads correctly.
 */
import "./styles.css";

import {mountLifecycle} from "./lifecycle.js";

/**
 * Mounts the home page's hero scene, if this page has one.
 *
 * Loaded lazily so that a page without a hero never pays for it, and so a WebGL failure here can never stop the
 * catalogue filter or the copy buttons from working.
 */
async function initHero() {
  const canvas = document.querySelector("[data-hero]");
  if (!canvas) return;

  try {
    const {mountHero} = await import("./hero.js");
    const teardown = mountHero(canvas);
    window.addEventListener("pagehide", teardown);
  } catch {
    // The hero is decoration. If it cannot run, the page is unchanged in every way that matters.
  }
}

/** Mounts a lifecycle scene on every canvas that carries its hook's permission set. */
function initLifecycles() {
  const teardowns = [];
  for (const canvas of document.querySelectorAll("canvas[data-permissions]")) {
    let permissions;
    try {
      permissions = JSON.parse(canvas.dataset.permissions);
    } catch {
      continue;
    }
    teardowns.push(mountLifecycle(canvas, permissions));
  }
  // Release GPU contexts if the page is restored from the back/forward cache with the scenes already running.
  window.addEventListener("pagehide", () => {
    for (const teardown of teardowns) teardown();
  });
}

/**
 * Filters the catalogue by free text and by tag, in place.
 *
 * Matching runs over the name, summary, family and tags, which is the same field set the MCP server's `search_hooks`
 * scores. A developer and an agent looking for the same thing find the same hooks.
 */
function initCatalogue() {
  const grid = document.querySelector("[data-catalogue]");
  if (!grid) return;

  const search = document.querySelector("[data-search]");
  const chips = [...document.querySelectorAll("[data-tag]")];
  const empty = document.querySelector("[data-empty]");
  const count = document.querySelector("[data-count]");
  const cards = [...grid.querySelectorAll("[data-haystack]")];
  let activeTag = null;

  function apply() {
    const terms = (search?.value ?? "").trim().toLowerCase().split(/\s+/).filter(Boolean);
    let visible = 0;

    for (const card of cards) {
      const haystack = card.dataset.haystack ?? "";
      const tags = (card.dataset.tags ?? "").split(",");
      const show = terms.every((term) => haystack.includes(term)) && (!activeTag || tags.includes(activeTag));
      card.hidden = !show;
      if (show) visible += 1;
    }

    if (empty) empty.hidden = visible !== 0;
    if (count) count.textContent = String(visible);

    // Reflect the filter in the URL so a filtered view can be linked and reloaded.
    const url = new URL(window.location.href);
    const query = search?.value.trim();
    query ? url.searchParams.set("q", query) : url.searchParams.delete("q");
    activeTag ? url.searchParams.set("tag", activeTag) : url.searchParams.delete("tag");
    window.history.replaceState(null, "", url);
  }

  function setTag(tag) {
    activeTag = tag;
    for (const chip of chips) chip.setAttribute("aria-pressed", String(chip.dataset.tag === activeTag));
  }

  search?.addEventListener("input", apply);
  for (const chip of chips) {
    chip.addEventListener("click", () => {
      setTag(chip.dataset.tag === activeTag ? null : chip.dataset.tag);
      apply();
    });
  }

  // `/` focuses search, the shortcut a developer already has in their fingers.
  document.addEventListener("keydown", (event) => {
    if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return;
    const tag = document.activeElement?.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA") return;
    event.preventDefault();
    search?.focus();
    search?.select();
  });

  // Restore a filter that arrived in the URL.
  const params = new URLSearchParams(window.location.search);
  if (search && params.has("q")) search.value = params.get("q");
  if (params.has("tag")) setTag(params.get("tag"));
  apply();
}

/** Wires the copy buttons the templates emit next to every address and install command. */
function initCopy() {
  if (!navigator.clipboard) {
    for (const button of document.querySelectorAll(".copy")) button.remove();
    return;
  }

  document.addEventListener("click", async (event) => {
    const button = event.target.closest(".copy");
    if (!button) return;

    const value = button.dataset.copy ?? button.closest(".copy-row")?.querySelector("code")?.textContent ?? "";
    try {
      await navigator.clipboard.writeText(value);
      const previous = button.textContent;
      button.textContent = "copied";
      button.classList.add("is-copied");
      setTimeout(() => {
        button.textContent = previous;
        button.classList.remove("is-copied");
      }, 1400);
    } catch {
      button.textContent = "failed";
      setTimeout(() => {
        button.textContent = "copy";
      }, 1400);
    }
  });
}

initHero();
initLifecycles();
initCatalogue();
initCopy();
