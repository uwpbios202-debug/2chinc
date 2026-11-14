#!/bin/sh
# Runs a migration file + a Mirror check file in ONE transaction that always ends in an error ('MIRROR CHECK RESULTS'),
# so everything is rolled back and nothing is kept. Writes happen only inside that transaction. Run only with Stephen's OK.
# Usage: sh ./.claude-tools/mirror-rollback-check.sh <migration.sql> <check.sql>
set -eu
cd "$(dirname "$0")/.."
mig="$1"; chk="$2"
tail -c 400 "$chk" | grep -q "raise exception 'MIRROR CHECK RESULTS" || { echo "Refusing: the check file must end with the MIRROR CHECK RESULTS raise" >&2; exit 2; }
set -a; . ./.env.supabase; set +a
tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.json"' EXIT
cat "$mig" > "$tmp"; printf '\n' >> "$tmp"; cat "$chk" >> "$tmp"
jq -n --rawfile q "$tmp" '{query: $q}' > "$tmp.json"
curl -sS -X POST "https://api.supabase.com/v1/projects/hvnsgwfcjpakvhhkfsuy/database/query" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" --data-binary "@$tmp.json" | sed 's/ | /\n  /g'
echo
