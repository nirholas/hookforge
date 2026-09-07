/** Small HTML helpers shared by every page template. No framework: the whole site is strings and a registry. */

/** Escapes text for interpolation into element content or a double-quoted attribute. */
export function esc(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Renders a template literal, dropping null and false so `${cond && html}` reads naturally. */
export function h(strings, ...values) {
  return strings.reduce((out, part, index) => {
    const value = values[index - 1];
    const rendered = value === null || value === undefined || value === false ? "" : Array.isArray(value) ? value.join("") : value;
    return out + rendered + part;
  });
}

/** Turns paragraphs separated by blank lines into `<p>` elements, escaping as it goes. */
export function paragraphs(text) {
  return String(text ?? "")
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .filter(Boolean)
    .map((block) => `<p>${esc(block)}</p>`)
    .join("\n");
}

/**
 * Wraps a NatSpec `@dev` block, which arrives as one long line, into readable paragraphs.
 *
 * Solidity collapses the block into a single string, so the only structure left is sentence boundaries. Grouping
 * every few sentences reproduces something close to the paragraphing the source had, which matters because these
 * descriptions are the substance of each page.
 */
export function prose(text, sentencesPerParagraph = 3) {
  const sentences = String(text ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .match(/[^.!?]+[.!?]+(\s|$)|[^.!?]+$/g);
  if (!sentences) return "";

  const blocks = [];
  for (let i = 0; i < sentences.length; i += sentencesPerParagraph) {
    blocks.push(sentences.slice(i, i + sentencesPerParagraph).join("").trim());
  }
  return blocks.filter(Boolean).map((block) => `<p>${esc(block)}</p>`).join("\n");
}

/** A copyable inline value, e.g. a contract address or an install command. */
export function copyable(value, label = value) {
  return h`<span class="copy-row"><code>${esc(label)}</code><button class="copy" type="button" data-copy="${esc(value)}" aria-label="Copy ${esc(label)}">copy</button></span>`;
}
