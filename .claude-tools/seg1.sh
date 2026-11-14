#!/bin/sh
# Segment 1 bug check: page status codes (read-only)
for u in /resident/ /resident/help/ /assets/portal/portal.js /assets/portal/step-up.js /assets/guide-zoom.js /unit-access/ /towing/ /documents/parking/ /assets/portal/parking-status.js /caseworker/ /resident/lease-info/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "https://2ndchinc.org$u")" "$u"
done
