#!/bin/sh
B=https://2ndchinc.org/mirror
curl -s $B/privacy/ | grep -c -E 'Draft\.|Last updated November 13, 2026'
curl -s $B/how-it-works/ | grep -c 'More about your voice'
curl -s $B/daily-number/ | grep -c -E 'SSI_FBR = |Benefits can go down'
curl -s $B/living-options/ | grep -c 'Other specialized housing.</strong>'
for p in how-it-works life-dimensions daily-number about privacy accessibility living-options sign-in forgot-password; do
  printf '%s ' $p; curl -s $B/$p/ | grep -c 'name="description"'
done
