#!/usr/bin/env bash
# Ships one hook end to end: generate its repository, prove it stands alone, publish it, and deploy its site.
#
#   ship.sh <slug> [--create]
#
# --create makes the GitHub repository and the Cloudflare Pages project first. Without it, both are assumed to exist.
# Requires GH_TOKEN, CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN in the environment.
#
# GitHub tokens here have a habit of expiring mid-run, and creating a repository needs a broader scope than pushing
# to one. Rather than let that stop a hook from shipping, a GitHub failure is recorded in tools/spinout/pending.txt
# and the site is deployed anyway: the demo is the part users touch, and the repository can be caught up later with
#
#   tools/spinout/ship-pending.sh
#
# That is the only thing written to disk outside the generated repository.
set -euo pipefail

SLUG="$1"
CREATE="${2:-}"
ROOT=/workspaces/hookforge
OUT=/workspaces/hookforge-spinouts
DIR="$OUT/$SLUG"
LIB="$ROOT/contracts/lib"

echo "== $SLUG"

node "$ROOT/tools/spinout/generate.mjs" "$SLUG" --out "$OUT" >/dev/null

# Prove it stands alone before publishing it. A repository that does not build is worse than no repository.
ln -sfn "$LIB" "$DIR/lib"
( cd "$DIR" && forge test >/dev/null 2>&1 ) || { echo "  FAILED: tests do not pass standalone"; exit 1; }
TESTS=$( cd "$DIR" && forge test 2>&1 | grep -oE '[0-9]+ tests passed' | head -1 )
echo "  standalone: $TESTS"

if [ "$CREATE" = "--create" ]; then
  DESC=$(python3 -c "import json;print(json.load(open('$DIR/hook.json'))['summary'][:340])")
  ( cd "$DIR" && gh repo create "nirholas/$SLUG" --public --description "$DESC" \
      --homepage "https://$SLUG.pages.dev" >/dev/null 2>&1 || true )
  curl -s -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" \
    -d "{\"name\":\"$SLUG\",\"production_branch\":\"main\"}" >/dev/null
fi

bash "$ROOT/tools/spinout/publish.sh" "$SLUG" "$DIR" >/dev/null

cd "$DIR"
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/nirholas/$SLUG.git"

PENDING="$ROOT/tools/spinout/pending.txt"
record_pending() {
  touch "$PENDING"
  grep -qxF "$SLUG" "$PENDING" || echo "$SLUG" >> "$PENDING"
  echo "  github: $1 (queued in tools/spinout/pending.txt)"
}

push_landed=0
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  # Somebody else may have committed to the published repository since the last ship. Rebase onto whatever is there
  # rather than failing the push or, worse, forcing over it.
  git fetch -q origin main
  git rebase -q origin/main >/dev/null 2>&1 || { echo "  FAILED: could not rebase onto origin/main"; exit 1; }
fi

if git push -q -u origin main >/dev/null 2>&1; then
  # Verify rather than assume. An earlier version piped the push through `|| true` and printed the local SHA, so a
  # failed authentication reported a successful push of a commit that never left the machine. Thirteen repositories
  # were silently behind before that was noticed.
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git ls-remote origin main 2>/dev/null | cut -f1)
  if [ "$LOCAL" = "$REMOTE" ] && [ -n "$REMOTE" ]; then
    echo "  pushed: ${LOCAL:0:7}"
    push_landed=1
    sed -i "/^$SLUG$/d" "$PENDING" 2>/dev/null || true
  fi
fi
[ "$push_landed" = "1" ] || record_pending "push did not land"

node web/build.mjs >/dev/null
URL=$(npx --yes wrangler@latest pages deploy web/dist --project-name "$SLUG" --branch main --commit-dirty=true 2>&1 \
      | grep -oE 'https://[a-z0-9.-]+\.pages\.dev' | tail -1)
echo "  deployed: $URL"

# Restore the symlink so the working copy stays runnable.
ln -sfn "$LIB" "$DIR/lib"
