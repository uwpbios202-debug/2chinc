#!/bin/sh
# Waits until the live mirror-client.js has the sign-out limits code (up to ~10 minutes).
n=0
until curl -s "https://2ndchinc.org/mirror/assets/mirror-client.js?w=$n" | grep -q "mirror_session_touch"; do
  n=$((n + 1))
  [ "$n" -gt 40 ] && echo "NOT LIVE after 10 minutes" && exit 1
  sleep 15
done
echo "LIVE"
