#!/bin/sh
# Syntax-check the Phase 6 finish files (T6.4 progress page, P5-02 Settings) and html-validate the touched pages.
# Usage: sh ./.claude-tools/mirror-p6finish-check.sh <scratch-dir>
cd "$(dirname "$0")/.." || exit 1
S="$1"
mkdir -p "$S"
node --check site/mirror/assets/progress-page.js && echo "ok   progress-page.js"
for f in site/mirror/my-mirror/progress/index.html site/mirror/my-mirror/settings/index.html site/mirror/my-mirror/index.html; do
  awk '/<script type="module">/{f=1;next} /<\/script>/{if(f){f=0}} f' "$f" > "$S/inline.mjs"
  if node --input-type=module --check < "$S/inline.mjs" > "$S/inline.err" 2>&1; then echo "ok   $f"; else echo "FAIL $f"; head -5 "$S/inline.err"; fi
done
if [ ! -f "$S/hv/node_modules/html-validate/bin/html-validate.js" ]; then
  mkdir -p "$S/hv" && (cd "$S/hv" && npm init -y > /dev/null && npm i html-validate@8.24.1 --silent > /dev/null 2>&1)
fi
printf '{"extends":["html-validate:recommended"],"rules":{"no-inline-style":"off","void-style":"off","long-title":"off"}}' > "$S/hv.json"
node "$S/hv/node_modules/html-validate/bin/html-validate.js" --config "$S/hv.json" --formatter text \
  site/mirror/my-mirror/progress/index.html site/mirror/my-mirror/settings/index.html site/mirror/my-mirror/index.html
echo "html-validate exit: $?"
