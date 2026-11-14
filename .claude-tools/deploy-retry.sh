#!/bin/sh
# Retries `sh tools/deploy.sh site` every 3 minutes, up to 10 tries, during a Cloudflare API outage. Stops at the first success.
cd "$(dirname "$0")/.."
n=1
while [ "$n" -le 10 ]; do
  echo "== try $n at $(date +%H:%M:%S)"
  out="$(sh tools/deploy.sh site 2>&1)"
  if echo "$out" | grep -q "Deployment complete"; then
    echo "$out" | grep "Deployment complete"
    echo "DEPLOYED (HEAD $(git log -1 --format=%h))"
    exit 0
  fi
  echo "$out" | grep -i "503\|error" | head -2
  n=$((n + 1))
  [ "$n" -le 10 ] && sleep 180
done
echo "GAVE UP after 10 tries"
exit 1
