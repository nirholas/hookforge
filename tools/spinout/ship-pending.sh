#!/usr/bin/env bash
# Catches up every spin-out whose GitHub side did not land when it was first shipped.
#
#   GH_TOKEN=<token with repo scope> tools/spinout/ship-pending.sh
#
# Creating a repository needs a broader scope than pushing to one, so a token that can push may still leave entries
# here. Each slug is re-shipped in full; a slug that succeeds is removed from the queue, and one that fails stays
# in it, so the script is safe to run repeatedly.
set -uo pipefail

ROOT=/workspaces/hookforge
PENDING="$ROOT/tools/spinout/pending.txt"

[ -s "$PENDING" ] || { echo "nothing pending"; exit 0; }

: "${GH_TOKEN:?set GH_TOKEN to a token that can create repositories under nirholas}"
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"

failed=0
while read -r slug; do
  [ -n "$slug" ] || continue
  bash "$ROOT/tools/spinout/ship.sh" "$slug" --create || failed=1
done < "$PENDING"

if [ -s "$PENDING" ]; then
  echo
  echo "still pending:"
  cat "$PENDING"
fi
exit "$failed"
