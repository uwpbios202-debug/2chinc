#!/bin/sh
# Run several rolled-back Mirror checks with one migration applied first; print pass/fail counts per check. (not committed)
# Usage: sh ./.claude-tools/run-checks-with.sh <migration or /dev/null> <check.sql> [<check.sql> ...]
mig="$1"; shift
for c in "$@"; do
  out="$(sh ./.claude-tools/mirror-rollback-check-sessions.sh "$mig" "$c" 2>&1)"
  if echo "$out" | grep -q "MIRROR CHECK RESULTS"; then
    t="$(echo "$out" | tr '|' '\n' | grep -c ': t\b')"
    f="$(echo "$out" | tr '|' '\n' | grep -c ': f\b')"
    echo "$(basename "$c"): passed $t, failed $f"
    [ "$f" = "0" ] || echo "$out" | tr '|' '\n' | grep ': f\b' | cut -c1-300
  else
    echo "$(basename "$c"): ERROR $(echo "$out" | grep -o 'ERROR:[^\\]*' | head -1 | cut -c1-300)"
  fi
done
