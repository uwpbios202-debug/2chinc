#!/bin/sh
# Saves live definitions of named functions (schema.name) to a folder, one .sql each (read-only).
# Usage: sh ./.claude-tools/dump-mirror-fns.sh <out_dir> <schema.fn> [schema.fn ...]
set -eu
cd "$(dirname "$0")/.."
out="$1"; shift
mkdir -p "$out"
for f in "$@"; do
  ./.claude-tools/supa-query.sh "select string_agg(pg_get_functiondef(p.oid), E'\n-- next overload\n') d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname = '$f'" > "$out/$f.json"
  node -e "const f=process.argv[1]; const j=JSON.parse(require('fs').readFileSync(f,'utf8')); require('fs').writeFileSync(f.replace(/\.json$/,'.sql'), (j[0]&&j[0].d)||'')" "$out/$f.json"
  rm -f "$out/$f.json"
  echo "$f $(wc -c < "$out/$f.sql")"
done
