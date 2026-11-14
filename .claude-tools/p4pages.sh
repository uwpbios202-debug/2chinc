#!/bin/sh
# Phase 4 Daily Number pages: status codes (read-only)
B=https://2ndchinc.org/mirror
for p in /daily-number/ /my-mirror/daily-number/ /my-mirror/daily-number/today/ /my-mirror/daily-number/survival/ /my-mirror/daily-number/stability/ /my-mirror/daily-number/aspirations/ /my-mirror/daily-number/income/ /my-mirror/daily-number/gap/ /my-mirror/daily-number/history/ /my-mirror/daily-number/reflect/ /assets/daily-number.js /assets/daily-number-page.js; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$B$p")
  echo "$c $p"
done
./.claude-tools/supa-query.sh "select value from portal_settings where key='mirror_signin_enabled'"
./.claude-tools/supa-query.sh "select (select count(*) from mirror.living_expenses) expenses, (select count(*) from mirror.income_sources) income, (select count(*) from mirror.daily_number_snapshots) snapshots"
