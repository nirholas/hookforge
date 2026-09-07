/**
 * Works out everything one hook needs to stand on its own.
 *
 * A hook in the catalogue imports shared bases, libraries and interfaces by relative path. A standalone repository
 * has to carry exactly those and nothing else: shipping the whole `src` tree would put twelve unrelated contracts in
 * a repository about one mechanism, and shipping too little produces a repository that does not compile.
 *
 * So the import graph is walked from the hook and from its test, and the closure is what gets copied. The layout is
 * preserved (`src/hooks`, `src/base`, `src/libraries`, `src/interfaces`) so that not one import path has to be
 * rewritten, which is the kind of transformation that silently breaks a contract months later.
 */
import {existsSync, readFileSync} from "node:fs";
import {dirname, join, normalize, relative} from "node:path";

/** Every relative import in `source`, resolved against the file it appeared in. */
function relativeImports(source, fromFile) {
  const matches = source.matchAll(/from\s+"(\.[^"]+\.sol)"/g);
  return [...matches].map((match) => normalize(join(dirname(fromFile), match[1])));
}

/**
 * The transitive closure of files `entry` needs, as paths relative to `root`.
 * @param root Absolute path to the contracts project.
 * @param entries Project-relative entry points, e.g. ["src/hooks/ArbTaxDecayHook.sol"].
 */
export function closure(root, entries) {
  const seen = new Set();
  const queue = [...entries];

  while (queue.length > 0) {
    const current = queue.shift();
    if (seen.has(current)) continue;

    const absolute = join(root, current);
    if (!existsSync(absolute)) continue;
    seen.add(current);

    for (const next of relativeImports(readFileSync(absolute, "utf8"), current)) {
      queue.push(relative(root, join(root, next)));
    }
  }
  return [...seen].sort();
}

/** The `uniswap-hooks`, `@uniswap` and `@openzeppelin` packages a set of files actually imports. */
export function externalPackages(root, files) {
  const packages = new Set();
  for (const file of files) {
    const source = readFileSync(join(root, file), "utf8");
    for (const match of source.matchAll(/from\s+"([^".][^"]*)"/g)) {
      const specifier = match[1];
      if (specifier.startsWith("@uniswap/v4-core")) packages.add("v4-core");
      else if (specifier.startsWith("@uniswap/v4-periphery")) packages.add("v4-periphery");
      else if (specifier.startsWith("@openzeppelin")) packages.add("openzeppelin-contracts");
      else if (specifier.startsWith("uniswap-hooks")) packages.add("uniswap-hooks");
      else if (specifier.startsWith("forge-std")) packages.add("forge-std");
      else if (specifier.startsWith("solmate")) packages.add("solmate");
      else if (specifier.startsWith("@prb/math")) packages.add("prb-math");
    }
  }
  return packages;
}
