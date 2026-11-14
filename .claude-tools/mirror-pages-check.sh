#!/bin/sh
# Syntax-check each page's inline module scripts and html-validate them.
# Usage: sh ./.claude-tools/mirror-pages-check.sh <scratch-dir-with-hv> <page.html> [page.html ...]
cd "$(dirname "$0")/.." || exit 1
S="$1"; shift
for f in "$@"; do
  awk '/<script type="module">/{f=1;next} /<\/script>/{if(f){f=0}} f' "$f" > "$S/inline.mjs"
  if node --input-type=module --check < "$S/inline.mjs" > "$S/inline.err" 2>&1; then echo "ok   $f"; else echo "FAIL $f"; head -5 "$S/inline.err"; fi
done
node "$S/hv/node_modules/html-validate/bin/html-validate.js" --config "$S/hv.json" --formatter text "$@" | grep -v "doctype-style"
echo "html-validate done"
