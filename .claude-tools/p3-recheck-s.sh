#!/bin/sh
# Re-runs earlier Mirror checks on top of one migration (each rolled back). Usage: sh .claude-tools/p3-recheck.sh <migration> <check-name>...
M="$1"; shift
for c in "$@"; do
  echo "== $c"
  sh ./.claude-tools/mirror-rollback-check-sessions.sh "$M" "tools/mirror-checks/$c.sql" | sed -n '/RESULTS/,/CONTEXT/p' | sed 's/ \nCONTEXT.*//'
done
