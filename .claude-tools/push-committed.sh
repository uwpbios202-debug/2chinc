#!/bin/sh
# Applies ONLY migrations that are committed in git (HEAD). Untracked or uncommitted files from other sessions are never copied,
# so they can never be swept into a push. Shows the dry run first, then pushes the very same folder.
# Usage: sh ./.claude-tools/push-committed.sh            (dry run only)
#        sh ./.claude-tools/push-committed.sh --yes      (dry run, then apply)
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/supabase/migrations"
cp supabase/config.toml "$tmp/supabase/"
[ -d supabase/.temp ] && cp -R supabase/.temp "$tmp/supabase/"
[ -f supabase/.env ] && cp supabase/.env "$tmp/supabase/"
[ -f supabase/.env.production ] && cp supabase/.env.production "$tmp/supabase/"
git ls-tree --name-only HEAD supabase/migrations/ | while read -r f; do git show "HEAD:$f" > "$tmp/$f"; done
echo "committed migrations copied: $(ls "$tmp/supabase/migrations" | wc -l)"
# local-only files are .gitignored ON PURPOSE (emails etc.) and already applied; copy them so the history matches
git ls-files --others --ignored --exclude-standard supabase/migrations/ | while read -r f; do cp "$f" "$tmp/$f"; done
echo "with local-only (gitignored) files: $(ls "$tmp/supabase/migrations" | wc -l)"
# untracked files: copy only those ALREADY APPLIED live (someone applied them uncommitted; the history must match);
# every other untracked file is someone's unfinished work and is left out
./.claude-tools/supa-query.sh "select version from supabase_migrations.schema_migrations" | grep -o '[0-9]\{14\}' > "$tmp/applied.txt"
echo "untracked files:"
git ls-files --others --exclude-standard supabase/migrations/ | while read -r f; do
  v="$(basename "$f" | cut -c1-14)"
  if grep -qx "$v" "$tmp/applied.txt"; then cp "$f" "$tmp/$f"; echo "  already live, copied: $f"; else echo "  NOT live, LEFT OUT: $f"; fi
done
set -a; . ./.env.supabase; set +a
echo "== dry run"
npx supabase db push --workdir "$tmp" --linked --include-all --dry-run 2>&1 | tee "$tmp/dry.txt"
[ "${1:-}" = "--yes" ] || exit 0
shift
# Apply ONLY if the dry-run list is exactly the expected versions given after --yes (so a migration someone else committed but
# has not applied can never go out unread).
[ "$#" -gt 0 ] || { echo "REFUSED: name the expected migration versions after --yes, e.g. --yes 20261119321000"; exit 3; }
grep -o '^ • [0-9]\{14\}' "$tmp/dry.txt" | grep -o '[0-9]\{14\}' | sort > "$tmp/would.txt"
printf '%s\n' "$@" | sort > "$tmp/expected.txt"
if ! cmp -s "$tmp/would.txt" "$tmp/expected.txt"; then
  echo "REFUSED: the dry run would apply:"; sed 's/^/  /' "$tmp/would.txt"
  echo "but you expected:"; sed 's/^/  /' "$tmp/expected.txt"; exit 4
fi
echo "== the dry run matches exactly; applying the same folder"
npx supabase db push --workdir "$tmp" --linked --include-all --yes
