#!/bin/sh
# Strict: a check passes only when the output is the MIRROR CHECK RESULTS line and every numbered result passes.
# Each result is "<n> <text>: t|f [detail]"; results are separated by " | " or newlines.
# A result PASSES when it says ": t", or shows a figure equal to its expected value ("94 (94)" or "(2): 2").
# A result FAILS when it says ": f" or shows a figure unlike its expected value ("93 (94)").
# Anything else is an INFO line (no expected value): shown, not counted as failed.
# Usage: sh ./.claude-tools/run-all-checks-strict.sh <migration.sql> <check1.sql> ...
cd "$(dirname "$0")/.."
mig="$1"; shift
okre=': t( |$)|(^|[^0-9])([0-9]+) \(\3\)( |$)|\(([0-9]+)\): \5( |$)'
figre=': f( |$)|[0-9]+ \([0-9]+\)|\([0-9]+\): [0-9]+'
for c in "$@"; do
  runner=mirror-rollback-check-sessions.sh
  grep -q "insert into auth.sessions" "$c" && runner=mirror-rollback-check.sh   # checks that make their own sessions
  out="$(sh ./.claude-tools/$runner "$mig" "$c" 2>&1)"
  if printf '%s' "$out" | grep -q 'MIRROR CHECK RESULTS'; then
    lines="$(printf '%s' "$out" | sed 's/\\n/\n/g' | sed 's/MIRROR CHECK RESULTS (all rolled back): /\n/' | tr '|' '\n' | grep -E '^[[:space:]]*[0-9]+[a-z]? ')"
    total="$(printf '%s\n' "$lines" | grep -c .)"
    good="$(printf '%s\n' "$lines" | grep -cE "$okre")"
    rest="$(printf '%s\n' "$lines" | grep -vE "$okre")"
    bad="$(printf '%s\n' "$rest" | grep -E "$figre")"
    nbad="$(printf '%s\n' "$bad" | grep -c .)"
    info=$((total - good - nbad))
    printf 'RESULTS %s  results=%s passed=%s failed=%s info=%s\n' "$(basename "$c")" "$total" "$good" "$nbad" "$info"
    [ "$nbad" != 0 ] && printf '%s\n' "$bad" | sed 's/^ */  FAILED /' | cut -c1-200
    [ "$info" != 0 ] && printf '%s\n' "$rest" | grep -vE "$figre" | sed 's/^ */  info /' | cut -c1-200
  else
    printf 'ERROR   %s  %s\n' "$(basename "$c")" "$(printf '%s' "$out" | cut -c1-300)"
  fi
done
exit 0
