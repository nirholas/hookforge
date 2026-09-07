#!/usr/bin/env bash
# Ships one hook end to end: generate its repository, prove it stands alone, publish it, and deploy its site.
#
#   ship.sh <slug> [--create]
#
# --create makes the GitHub repository and the Cloudflare Pages project first. Without it, both are assumed to exist.
# Requires GH_TOKEN, CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN in the environment. Nothing is written to disk.
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
git push -q -u origin main 2>&1 | tail -1 || true

node web/build.mjs >/dev/null
URL=$(npx --yes wrangler@latest pages deploy web/dist --project-name "$SLUG" --branch main --commit-dirty=true 2>&1 \
      | grep -oE 'https://[a-z0-9.-]+\.pages\.dev' | tail -1)
echo "  deployed: $URL"

# Restore the symlink so the working copy stays runnable.
ln -sfn "$LIB" "$DIR/lib"
