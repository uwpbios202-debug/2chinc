#!/bin/sh
# T6.3 headless check: stubbed copies of the three pages under site/mirror/_t63/, driven in headless Chrome, then removed.
set -eu
cd "$(dirname "$0")/.."
t=site/mirror/_t63
mkdir -p "$t"
cp .claude-tools/t63-stub-client.js "$t/stub-client.js"
cp .claude-tools/t63-drive.js "$t/drive.js"
sed 's|/mirror/assets/mirror-client.js?v=20261113d|/mirror/_t63/stub-client.js|' site/mirror/assets/plan-page.js > "$t/plan-page.js"
for k in plan actions milestones; do
  sed -e 's|/mirror/assets/plan-page.js?v=20261113a|/mirror/_t63/plan-page.js|' -e 's|</body>|<script type="module" src="/mirror/_t63/drive.js"></script></body>|' \
    "site/mirror/my-mirror/$k/index.html" > "$t/$k.html"
  "/c/Program Files/Google/Chrome/Application/chrome.exe" --headless=new --disable-gpu --no-first-run --user-data-dir="$TEMP/t63prof" \
    --virtual-time-budget=9000 --dump-dom "http://127.0.0.1:8787/mirror/_t63/$k.html" 2>/dev/null | sed -n '/<pre id="T63OUT">/,/<\/pre>/p'
done
rm -rf "$t"
