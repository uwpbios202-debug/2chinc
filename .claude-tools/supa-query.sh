#!/usr/bin/env bash
# Read-only Supabase SQL helper for Claude Code.
# Usage: ./.claude-tools/supa-query.sh "select ... from ..."
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo 'usage: ./.claude-tools/supa-query.sh "SELECT ..."' >&2
  exit 1
fi

if [ ! -f .env.supabase ]; then
  echo "ERROR: .env.supabase not found in $(pwd)" >&2
  exit 1
fi

# Normalize: trim whitespace and one trailing semicolon, lowercase copy for checks
sql="$1"
sql="$(printf '%s' "$sql" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/;[[:space:]]*$//')"
lc="$(printf '%s' "$sql" | tr '[:upper:]' '[:lower:]')"

case "$lc" in
  select*|with*|explain*) ;;
  *) echo "BLOCKED: this helper is read-only (SELECT / WITH / EXPLAIN only)." >&2; exit 2 ;;
esac

case "$sql" in
  *';'*) echo "BLOCKED: multiple statements are not allowed." >&2; exit 2 ;;
esac

if printf '%s' "$lc" | grep -Eq '(^|[^a-z_])(insert|update|delete|drop|alter|truncate|grant|revoke|create|copy|call|do|merge|vacuum|reindex|refresh|comment|lock|set|reset|execute)([^a-z_]|$)'; then
  echo "BLOCKED: write/DDL keyword detected. Run write operations separately with user approval." >&2
  exit 2
fi

set -a
. ./.env.supabase
set +a

: "${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN missing from .env.supabase}"

payload="$(jq -n --arg q "$sql" '{query: $q}')"

curl -sS -X POST \
  "https://api.supabase.com/v1/projects/hvnsgwfcjpakvhhkfsuy/database/query" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$payload"
echo