#!/bin/sh
for u in https://2ndchinc.org/staff/resources/ https://2ndchinc.org/navigator/ "https://2ndchinc.org/assets/portal/chpms.js?v=20261113a"; do
  printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' "$u")"; echo "$u"
done
printf 'script has the life area filter: '; curl -s "https://2ndchinc.org/assets/portal/chpms.js?v=20261113a" | grep -c "chpms_life_areas"
printf 'staff page loads new version: '; curl -s https://2ndchinc.org/staff/resources/ | grep -c "chpms.js?v=20261113a"
