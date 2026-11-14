#!/bin/sh
# Bug-check segment 2: owner portal + seller page status codes
for u in \
  https://2ndchinc.org/seller/ \
  https://2ndchinc.org/association-owners/roca1/ \
  https://2ndchinc.org/association-owners/roca1/help/ \
  https://2ndchinc.org/assets/portal/portal.js
do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "$u")" "$u"
done
