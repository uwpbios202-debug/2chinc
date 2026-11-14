#!/bin/sh
# Pushes migrations from a temporary copy of supabase/ that leaves out the named migration files (other sessions' unfinished work).
# Usage: sh ./.claude-tools/push-one-migration.sh "<skip1.sql> <skip2.sql>" [--dry-run | --yes]
set -eu
cd "$(dirname "$0")/.."
skip=" $1 "; shift
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/supabase/migrations"
cp supabase/config.toml "$tmp/supabase/"
[ -d supabase/.temp ] && cp -R supabase/.temp "$tmp/supabase/"
[ -f supabase/.env ] && cp supabase/.env "$tmp/supabase/"
[ -f supabase/.env.production ] && cp supabase/.env.production "$tmp/supabase/"
for f in supabase/migrations/*.sql; do
  b="$(basename "$f")"
  case "$skip" in *" $b "*) echo "leaving out $b" ;; *) cp "$f" "$tmp/supabase/migrations/" ;; esac
done
set -a; . ./.env.supabase; set +a
npx supabase db push --workdir "$tmp" --linked --include-all "$@"
