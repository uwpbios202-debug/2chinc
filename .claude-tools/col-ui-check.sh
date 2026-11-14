#!/bin/sh
# LOCAL CHECK ONLY: drives the stability page with stubbed benchmarks in headless Chrome (phone and desktop width), then removes the copies.
cd "$(dirname "$0")/.."
node .claude-tools/col-ui-prep.mjs
node .claude-tools/dn-stub-server.mjs > "$TEMP/col-srv.txt" 2>&1 &
srv=$!
sleep 1
for w in 390 1280; do
  echo "== width $w"
  "/c/Program Files/Google/Chrome/Application/chrome.exe" --headless=new --disable-gpu --no-first-run --user-data-dir="$TEMP/colprof" --window-size=$w,900 \
    --virtual-time-budget=12000 --dump-dom "http://127.0.0.1:8788/mirror/_col/stability.html" > "$TEMP/col-$w.html" 2>/dev/null
  sed -n '/<pre id="COLOUT">/,/<\/pre>/p' "$TEMP/col-$w.html"
  echo "(dom bytes: $(wc -c < "$TEMP/col-$w.html"))"
done
kill $srv
cat "$TEMP/col-srv.txt"
[ -n "$KEEP" ] || rm -rf site/mirror/_col
