#!/bin/sh
# Phase 4 step 4 pages live: status codes and script versions (read-only)
B=https://2ndchinc.org/mirror/my-mirror/daily-number
for p in /plan/ /what-if/ /benefits/ /household/ /; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$B$p")
  v=$(curl -s "$B$p" | grep -o "daily-number-page.js?v=[0-9a-z]*")
  echo "$c $p $v"
done
curl -s "https://2ndchinc.org/mirror/assets/daily-number-page.js?v=20261113j" | grep -c "function whatIfPage\|function benefits(\|function household(\|function plan("
curl -s "https://2ndchinc.org/mirror/assets/daily-number.js?v=20261113e" | grep -c "export function whoPays\|export function planEffect"
