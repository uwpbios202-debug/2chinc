#!/bin/sh
# Runs one migration with each listed Mirror check, each in its own rolled-back transaction; prints one summary line per check.
# Usage: sh ./.claude-tools/run-mirror-checks.sh <migration.sql> <check1.sql> [check2.sql ...]
cd "$(dirname "$0")/.."
mig="$1"; shift
for c in "$@"; do
  out="$(sh ./.claude-tools/mirror-rollback-check-sessions.sh "$mig" "$c" 2>&1)"
  fails="$(printf '%s' "$out" | grep -c ': f$\|: f \|ERROR:  [0-9A-Z]\{5\}: [^M]')"
  printf '%s | fails=%s\n' "$(basename "$c")" "$fails"
  printf '%s\n' "$out" | grep -v '^$' | sed 's/^/    /' | grep ': f\|ERROR:  [0-9A-Z]\{5\}: [^M]' || true
done
