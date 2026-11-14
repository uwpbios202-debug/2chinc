#!/bin/sh
# Pushes ONLY the named migration files. The temporary copy holds the migrations already applied on the remote plus the named
# ones, so another session's new file can never slip in between a dry run and the push.
# Usage: sh ./.claude-tools/push-only.sh "<file1.sql> [file2.sql]" [--dry-run | --yes]
set -eu
cd "$(dirname "$0")/.."
only=" $1 "; shift
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/supabase/migrations"
cp supabase/config.toml "$tmp/supabase/"
[ -d supabase/.temp ] && cp -R supabase/.temp "$tmp/supabase/"
./.claude-tools/supa-query.sh "select version from supabase_migrations.schema_migrations order by 1" | grep -o '"version":"[0-9]*"' | grep -o '[0-9]\+' > "$tmp/applied.txt"
for f in supabase/migrations/*.sql; do
  b="$(basename "$f")"; ver="${b%%_*}"
  if grep -qx "$ver" "$tmp/applied.txt"; then cp "$f" "$tmp/supabase/migrations/"
  else case "$only" in *" $b "*) echo "pushing $b"; cp "$f" "$tmp/supabase/migrations/" ;; *) echo "leaving out $b" ;; esac
  fi
done
set -a; . ./.env.supabase; set +a
npx supabase db push --workdir "$tmp" --linked --include-all "$@"
