#!/bin/sh
# Phase 4 Daily Number checks against the live database (rolled back): prints each result part; "FAIL" lines end in ": f".
cd "$(dirname "$0")/.."
E=/c/Users/mkepr/AppData/Local/Temp/claude/9595fc9777f5ef61/c94aeaff-31ff-48c1-90d5-23878956dae6/scratchpad/empty.sql
for f in t42-daily-number-check.sql t43-daily-number-usable-check.sql t44-daily-number-plan-check.sql t45-dn-change-log-check.sql; do
  [ -f "tools/mirror-checks/$f" ] || { echo "missing $f"; continue; }
  out=$(sh ./.claude-tools/mirror-rollback-check-sessions.sh "$E" "tools/mirror-checks/$f" 2>&1)
  echo "$out" | grep -q "MIRROR CHECK RESULTS" || { echo "$f: NO RESULT: $(echo "$out" | cut -c1-300)"; continue; }
  fails=$(echo "$out" | tr '|' '\n' | grep -c ": f *\$\|: f \\\\n\|: false")
  echo "$f parts: $(echo "$out" | tr '|' '\n' | wc -l), failed: $fails"
  echo "$out" | tr '|' '\n' | grep ": f *\$\|: f \\\\n\|: false" | cut -c1-200
done
