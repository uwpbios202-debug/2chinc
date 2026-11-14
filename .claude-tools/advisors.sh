#!/usr/bin/env bash
# Read-only: fetch the Supabase advisor lints (security or performance) and write them to a file.
# Usage: ./.claude-tools/advisors.sh security|performance <out.json>
set -euo pipefail
cd "$(dirname "$0")/.."
kind="${1:-security}"; out="${2:-/dev/stdout}"
set -a; . ./.env.supabase; set +a
curl -sS "https://api.supabase.com/v1/projects/hvnsgwfcjpakvhhkfsuy/advisors/$kind" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" > "$out"
echo "saved $(wc -c < "$out") bytes"
