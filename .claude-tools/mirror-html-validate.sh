#!/bin/sh
# Validate every committed Mirror page with html-validate (installed in a scratch folder, not the repo).
# Usage: sh ./.claude-tools/mirror-html-validate.sh <install-dir> <config.json>
cd "$(dirname "$0")/.." || exit 1
HV="$1/node_modules/html-validate/bin/html-validate.mjs"
CFG="$2"
git ls-files site/mirror | grep 'index.html$' > "$1/pages.txt"
echo "pages: $(wc -l < "$1/pages.txt")"
node "$HV" --config "$CFG" --formatter text $(cat "$1/pages.txt") > "$1/result.txt" 2>&1
echo "exit: $?"
echo "== problems by rule"
grep -oE '\(([a-z0-9-]+)\)$' "$1/result.txt" | sort | uniq -c | sort -rn
echo "== problems by page"
cut -d: -f1 "$1/result.txt" | grep '^site/' | sort | uniq -c | sort -rn
tail -3 "$1/result.txt"
