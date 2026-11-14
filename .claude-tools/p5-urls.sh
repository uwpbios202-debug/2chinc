#!/bin/sh
# Phase 5 live check: status codes of the new pages and assets, and that each asset matches the committed file.
cd "$(dirname "$0")/.."
for u in /mirror/living-options/ /mirror/my-mirror/living/ /mirror/my-mirror/abilities/activities/ /mirror/my-mirror/abilities/areas/ /mirror/my-mirror/abilities/ /mirror/workspace/person/ /mirror/how-it-works/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "https://2ndchinc.org$u")" "$u"
done
for f in functional-data.js living-options.js functional-page.js housing-page.js; do
  live="$(curl -s "https://2ndchinc.org/mirror/assets/$f?v=20261113a" | tr -d '\r' | md5sum | cut -c1-8)"
  head="$(git show "HEAD:site/mirror/assets/$f" | tr -d '\r' | md5sum | cut -c1-8)"
  printf '%s live=%s head=%s %s\n' "$f" "$live" "$head" "$([ "$live" = "$head" ] && echo MATCH || echo DIFF)"
done
curl -s https://2ndchinc.org/mirror/living-options/ | grep -c 'noindex'
