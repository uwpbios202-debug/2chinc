#!/bin/sh
# Like push-one-migration.sh but leaves out SEVERAL named migration files (other sessions' unfinished work).
# Usage: sh ./.claude-tools/push-except.sh [--dry-run] <file1.sql> [file2.sql ...]
set -eu
cd "$(dirname "$0")/.."
dry=""
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "--yes" ]; then dry="$1"; shift; fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/supabase/migrations"
cp supabase/config.toml "$tmp/supabase/"
[ -d supabase/.temp ] && cp -R supabase/.temp "$tmp/supabase/"
[ -f supabase/.env ] && cp supabase/.env "$tmp/supabase/"
[ -f supabase/.env.production ] && cp supabase/.env.production "$tmp/supabase/"
cp supabase/migrations/*.sql "$tmp/supabase/migrations/"
for s in "$@"; do
  rm -f "$tmp/supabase/migrations/$s"
  echo "leaving out $s"
done
set -a; . ./.env.supabase; set +a
npx supabase db push --workdir "$tmp" --linked --include-all $dry
