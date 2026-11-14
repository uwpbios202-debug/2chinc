#!/bin/sh
# Segment 10 read-only check: public pages status codes
for p in "" rent-help/ who-we-serve/ contact/ documents/ privacy/ robots.txt sitemap/ sitemap.xml navigator/ mirror/ mirror/sign-in/; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "https://2ndchinc.org/$p")
  echo "$code https://2ndchinc.org/$p"
done
echo "portal.js cache: $(curl -sI https://2ndchinc.org/assets/portal/portal.js | grep -i '^cache-control' | tr -d '\r')"
ls dist 2>/dev/null | head -1 >/dev/null && find dist -name wrangler-account.json -o -name .wrangler 2>/dev/null | head
