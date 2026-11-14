#!/bin/sh
# Read-only examination of Mirror Phase 1 (live pages + local source facts).
cd "$(dirname "$0")/.." || exit 1
echo "== contrast pair count"
node tools/mirror-checks/contrast.mjs | grep -c " ok "
node tools/mirror-checks/contrast.mjs | grep -v " ok " | grep -i -E "fail|needs" | head
echo "== live status + noindex (header or meta) + cache-control"
for p in / about/ how-it-works/ life-dimensions/ privacy/ accessibility/ forgot-password/ sign-in/ daily-number/ styleguide/ demo/conversation/ my-mirror/ workspace/ admin/ \
         assets/mirror.css assets/mirror-ui.js assets/mirror-voice.js assets/mirror-client.js assets/mirror-listen.js assets/dimensions.js; do
  u="https://2ndchinc.org/mirror/$p"
  h=$(curl -s -o /tmp/mp1.body -D - "$u")
  code=$(printf '%s' "$h" | head -1 | awk '{print $2}')
  xr=$(printf '%s' "$h" | grep -i '^x-robots-tag' | tr -d '\r' | cut -d' ' -f2-)
  cc=$(printf '%s' "$h" | grep -i '^cache-control' | tr -d '\r' | cut -d' ' -f2-)
  meta=$(grep -c -i 'name="robots"[^>]*noindex' /tmp/mp1.body)
  echo "$code  $p  robots-hdr=[$xr] meta-noindex=$meta  cache=[$cc]"
done
echo "== local pages: inline <script> without src (CSP risk)"
grep -L "noindex" site/mirror/*/index.html site/mirror/*/*/index.html 2>/dev/null | sed 's/^/no-noindex: /'
grep -l -E "<script>|<script type=\"module\">" site/mirror/index.html site/mirror/*/index.html site/mirror/*/*/index.html 2>/dev/null | sed 's/^/inline-script: /' | head -40
echo "== @ts-check on Mirror assets"
grep -L "@ts-check" site/mirror/assets/*.js | sed 's/^/missing ts-check: /'
echo "== third-party hosts referenced"
grep -h -o -E "https://[a-zA-Z0-9.-]+" site/mirror -r | sort | uniq -c | sort -rn | head -15
echo "== links from main site into /mirror/"
grep -rl "/mirror/" site --include=*.html | grep -v "^site/mirror/" | head
echo "== mirror headers rules"
grep -n -i -A3 "mirror" site/_headers
echo "== T1.4 conventions doc"
ls docs/human-mirror | grep -i -E "conven|environ" || echo "none"
echo "== signin switch"
./.claude-tools/supa-query.sh "select key, value from portal_settings where key like 'mirror%'"
