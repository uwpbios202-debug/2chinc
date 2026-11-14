#!/bin/sh
# Runs every listed Mirror check with fix 5 and prints passes / fails per check.
cd "$(dirname "$0")/.."
M=supabase/migrations/20261119269000_mirror_session_fresh.sql
for c in t2-identity-check t24-signin-check t25-admin-people-check t31-assessment-engine-check t33-reflection-questions-check t35-dimension-questions-check t36-privacy-settings-check t42-daily-number-check t43-daily-number-usable-check p2-fix01-invitation-check p2-fix02-recorded-consent-check p2-fix03-link-needs-yes-check p2-fix04-platform-admin-visible-check p3-fix06-question-versions-check p3-fix07-save-counts-check p3-fix08-answers-no-truncate-check
do
  out="$(sh ./.claude-tools/mirror-rollback-check-sessions.sh "$M" "tools/mirror-checks/$c.sql" 2>&1)"
  t="$(printf '%s' "$out" | grep -o ': t\b' | wc -l)"; f="$(printf '%s' "$out" | grep -o ': f\b' | wc -l)"
  r="$(printf '%s' "$out" | grep -c 'MIRROR CHECK RESULTS')"
  printf '%-40s pass=%s fail=%s finished=%s\n' "$c" "$t" "$f" "$r"
  [ "$r" = "1" ] && [ "$f" = "0" ] || printf '%s\n' "$out" | head -c 700
done
