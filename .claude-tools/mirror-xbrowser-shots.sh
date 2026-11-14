#!/bin/sh
# Headless Firefox + Edge screenshots of Mirror pages at phone widths (read-only, public pages + styleguide).
# Output: PNGs in the scratchpad folder given as $1.
OUT="$1"
[ -n "$OUT" ] || exit 1
mkdir -p "$OUT/ffprof" "$OUT/edgeprof"
FF="/c/Program Files/Mozilla Firefox/firefox.exe"
ED="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
WOUT=$(cygpath -w "$OUT")
for p in "" about/ how-it-works/ life-dimensions/ privacy/ accessibility/ forgot-password/ daily-number/ styleguide/ demo/conversation/; do
  n=$(printf '%s' "home/$p" | tr '/' '_' | sed 's/_$//')
  for w in 320 390; do
    "$FF" --headless -no-remote -profile "$(cygpath -w "$OUT/ffprof")" --window-size=$w,2400 --screenshot "$WOUT\\ff-$n-$w.png" "https://2ndchinc.org/mirror/$p" > /dev/null 2>&1
    "$ED" --headless=new --disable-gpu --user-data-dir="$(cygpath -w "$OUT/edgeprof")" --window-size=$w,2400 --virtual-time-budget=6000 --screenshot="$WOUT\\edge-$n-$w.png" "https://2ndchinc.org/mirror/$p" > /dev/null 2>&1
  done
done
ls "$OUT"/*.png | wc -l
