#!/bin/sh
for u in https://2ndchinc.org/mirror/my-mirror/referrals/ https://2ndchinc.org/mirror/workspace/referrals/ https://2ndchinc.org/mirror/my-mirror/resources/ https://2ndchinc.org/mirror/workspace/person/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "$u")" "$u"
done
