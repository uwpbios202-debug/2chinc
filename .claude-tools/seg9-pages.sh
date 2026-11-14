#!/bin/sh
for u in https://2ndchinc.org/waitlist/ https://2ndchinc.org/staff/waitlist/ https://2ndchinc.org/leasing/apply/ https://2ndchinc.org/staff/efile/ https://2ndchinc.org/navigator/ https://2ndchinc.org/staff/navigators/ https://2ndchinc.org/navigator/unit/ https://2ndchinc.org/staff/resources/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "$u")" "$u"
done
