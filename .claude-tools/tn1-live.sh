#!/bin/sh
for u in https://2ndchinc.org/navigator/ https://2ndchinc.org/staff/navigators/ https://2ndchinc.org/navigator/unit/ "https://2ndchinc.org/assets/portal/nav-common.js?v=20261113d"; do
  printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' "$u")"; echo "$u"
done
printf 'new script has the section: '; curl -s "https://2ndchinc.org/assets/portal/nav-common.js?v=20261113d" | grep -c "mirror_need_id"
printf 'Navigator page loads the new version: '; curl -s https://2ndchinc.org/navigator/ | grep -c "nav-common.js?v=20261113d"
