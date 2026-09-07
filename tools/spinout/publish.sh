#!/usr/bin/env bash
# Turns a generated hook directory into a published GitHub repository.
#
# Submodules are recorded as gitlinks against pinned commits rather than cloned, because cloning six dependencies into
# fifty repositories costs an hour and several gigabytes to produce exactly the same tree. `git clone --recurse-submodules`
# on the published repository fetches them the usual way.
#
# Usage: publish.sh <slug> <dir>
# Requires GH_TOKEN in the environment. The token is never written to disk.
set -euo pipefail

SLUG="$1"
DIR="$2"
OWNER="nirholas"

declare -A PINS=(
  [forge-std]="886b4f8b63409ef474542de6394d25a9b5908ed3 https://github.com/foundry-rs/forge-std"
  [v4-core]="46c6834698c48bc4a463a86d8420f4eb1d7f3b75 https://github.com/Uniswap/v4-core"
  [v4-periphery]="dce236d4e2057422d0791d9a973a58765eb46f65 https://github.com/Uniswap/v4-periphery"
  [openzeppelin-contracts]="bbf3600dc2fd09c7409c5e9d65e2faea36f35115 https://github.com/OpenZeppelin/openzeppelin-contracts"
  [solmate]="89365b880c4f3c786bdd453d4b8e8fe410344a69 https://github.com/transmissions11/solmate"
  [uniswap-hooks]="2ae32be4906d300fc49b4384842ef6bc3e902d73 https://github.com/OpenZeppelin/uniswap-hooks"
  [prb-math]="5010593538ab97f92f96175daf5ab9337168964f https://github.com/PaulRBerg/prb-math"
)

cd "$DIR"

# The symlink used for local verification must never reach the repository.
[ -L lib ] && rm -f lib

rm -f .gitmodules
for name in forge-std v4-core v4-periphery openzeppelin-contracts solmate uniswap-hooks prb-math; do
  read -r sha url <<<"${PINS[$name]}"
  printf '[submodule "lib/%s"]\n\tpath = lib/%s\n\turl = %s\n' "$name" "$name" "$url" >> .gitmodules
done

git init -q -b main 2>/dev/null || true
git config user.name "nirholas"
git config user.email "claudescammer@outlook.com"
git config commit.gpgsign false

git add -A
for name in forge-std v4-core v4-periphery openzeppelin-contracts solmate uniswap-hooks prb-math; do
  read -r sha url <<<"${PINS[$name]}"
  git update-index --add --cacheinfo "160000,$sha,lib/$name"
done

if git rev-parse HEAD >/dev/null 2>&1; then
  git commit -q -m "chore: regenerate from the HookForge catalogue" || echo "  nothing to commit"
else
  git commit -q -F - <<'MSG'
feat: a production Uniswap v4 hook, its tests, its docs and its site

Generated from the HookForge catalogue, which is where these hooks are written
and tested together. This repository is where this one mechanism is published,
documented and deployed on its own.

Everything here is derived from the contract: the README prose is its NatSpec,
the parameter table is its configure ABI, the callbacks the site lights up are
the flags it declares, and hook.json is what specURI() points at. Documentation
drift is not managed, it is impossible.

The hook is unaudited, has no owner, no pause switch and no upgrade path, and
states in its own source what it does not do.
MSG
fi
echo "  committed $(git rev-list --count HEAD) commit(s), $(git ls-files | wc -l) files"
