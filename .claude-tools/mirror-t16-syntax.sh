#!/bin/sh
# Syntax-check the inline module scripts of the T1.6 pages and the touched shared pages (extracts each <script type="module"> body).
cd "$(dirname "$0")/.." || exit 1
for f in site/mirror/my-mirror/conversation/index.html site/mirror/workspace/conversation/index.html site/mirror/my-mirror/settings/index.html \
         site/mirror/my-mirror/index.html site/mirror/workspace/person/index.html site/mirror/demo/conversation/index.html; do
  awk '/<script type="module">/{f=1;next} /<\/script>/{if(f){f=0}} f' "$f" > "$TEMP/inline.mjs"
  if node --input-type=module --check < "$TEMP/inline.mjs" > "$TEMP/inline.err" 2>&1; then echo "ok   $f"; else echo "FAIL $f"; head -5 "$TEMP/inline.err"; fi
done
