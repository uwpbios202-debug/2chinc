#!/bin/sh
# Live check of the CHPMS pages and scripts (status codes and that the deployed files are the committed ones).
for p in /staff/resources/ /navigator/ /assets/portal/chpms.js /assets/portal/staff-nav.js; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "https://2ndchinc.org$p")" "$p"
done
curl -s https://2ndchinc.org/assets/portal/chpms.js | cmp -s - site/assets/portal/chpms.js && echo "chpms.js live = committed" || echo "chpms.js DIFFERS"
curl -s https://2ndchinc.org/navigator/ | grep -c 'data-tab="resources"'
curl -s https://2ndchinc.org/assets/portal/staff-nav.js | grep -c '/staff/resources/'
