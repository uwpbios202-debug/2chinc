#!/bin/sh
for p in / /rent-help/ /who-we-serve/ /contact/ /documents/ /privacy/ /robots.txt /sitemap.xml /sitemap/ /navigator/ /staff/navigators/ /staff/aid/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "https://2ndchinc.org$p")" "$p"
done
ls -d dist/.wrangler 2>/dev/null; find dist -name wrangler-account.json 2>/dev/null
