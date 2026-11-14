#!/bin/sh
# Read-only re-verification of Mirror Phase 1 against MASTER_ROADMAP acceptance criteria.
cd "$(dirname "$0")/.." || exit 1
B=https://2ndchinc.org
T=$(mktemp -d)

echo "== T1.1 contrast"
node tools/mirror-checks/contrast.mjs > "$T/c.txt"; echo "pairs ok: $(grep -c ' ok ' "$T/c.txt")  not ok: $(grep -c -E '^ *(FAIL|fail)' "$T/c.txt")  last: $(tail -1 "$T/c.txt")"

echo "== T1.1 module syntax + ts-check"
for f in site/mirror/assets/*.js; do
  if node --input-type=module --check < "$f" > /dev/null 2>&1; then r=ok; else r=FAIL; fi
  if grep -q "@ts-check" "$f"; then t=ts; else t=NO-TS; fi
  echo "$r $t $f"
done

echo "== T1.1/T1.2 every local Mirror page: noindex, live 200, live = HEAD"
find site/mirror -name index.html | sort > "$T/pages"
echo "local pages: $(wc -l < "$T/pages")"
while read -r f; do
  p="/${f#site/}"; p="${p%index.html}"
  code=$(curl -s -o "$T/live.html" -w '%{http_code}' "$B$p")
  ni=$(grep -c -i 'name="robots"[^>]*noindex' "$T/live.html")
  git show "HEAD:$f" > "$T/head.html" 2>/dev/null || echo "" > "$T/head.html"
  # live differs from HEAD only by Cloudflare rewrites; compare after stripping CR and the email-decode script tag
  tr -d '\r' < "$T/live.html" | grep -v 'email-decode' > "$T/a"; tr -d '\r' < "$T/head.html" | grep -v 'email-decode' > "$T/b"
  if cmp -s "$T/a" "$T/b"; then same=same; else same=DIFF; fi
  if git diff --quiet HEAD -- "$f"; then wt=clean; else wt=uncommitted-edit; fi
  [ "$code" = 200 ] && [ "$ni" -ge 1 ] && [ "$same" = same ] && continue
  echo "CHECK $code noindex=$ni live-vs-HEAD=$same worktree=$wt $p"
done < "$T/pages"
echo "(only problem pages listed above)"

echo "== asset versions referenced (local) and whether each versioned URL serves HEAD's file"
grep -rhoE "/mirror/assets/[a-z-]+\.(js|css)\?v=[0-9a-z]+" site/mirror | sort | uniq -c
grep -rhoE "/mirror/assets/[a-z-]+\.(js|css)\?v=[0-9a-z]+" site/mirror | sort -u > "$T/assets"
while read -r u; do
  f="site${u%%\?*}"
  curl -s "$B$u" | tr -d '\r' > "$T/la"; git show "HEAD:$f" | tr -d '\r' > "$T/lb"
  if cmp -s "$T/la" "$T/lb"; then echo "same $u"; else echo "DIFF $u"; fi
done < "$T/assets"

echo "== outside hosts: Mirror pages + every shared script they load"
grep -rhoE 'src="/assets/[^"?]+|from "/assets/[^"?]+' site/mirror | sed -E 's/^(src="|from ")//' | sort -u > "$T/shared"
cat "$T/shared" | sed 's/^/shared: /'
( grep -rhoE "https://[a-zA-Z0-9.-]+" site/mirror; while read -r s; do grep -hoE "https://[a-zA-Z0-9.-]+" "site$s"; done < "$T/shared" ) | sort | uniq -c | sort -rn

echo "== T1.2 link walk (live)"
node .claude-tools/mirror-linkwalk.mjs "$B" | tail -2

echo "== email links live (privacy, accessibility)"
for p in privacy accessibility; do echo "$p: mailto=$(curl -s "$B/mirror/$p/" | grep -c 'mailto:info@2ndchinc.org') cdn-cgi=$(curl -s "$B/mirror/$p/" | grep -c 'email-protection')"; done

echo "== no main-site page links to /mirror/"
grep -rl "/mirror/" site --include=*.html | grep -v "^site/mirror/" | wc -l

echo "== T1.3 gate: signed-out workspace redirect is client-side; sign-in switch"
./.claude-tools/supa-query.sh "select key, value from portal_settings where key = 'mirror_signin_enabled'"
./.claude-tools/supa-query.sh "select p.proname, p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('mirror_whoami','signin_email_on_file')"

echo "== T1.4 doc present + linked"
ls docs/human-mirror/CONVENTIONS.md && grep -c "CONVENTIONS.md" docs/human-mirror/README.md docs/human-mirror/MASTER_ROADMAP.md

echo "== T1.5 voice: Speak/Read aloud wiring"
grep -c "export function" site/mirror/assets/mirror-voice.js
grep -l "mirror-voice.js" -r site/mirror --include=*.html | wc -l

echo "== cache headers"
curl -sI "$B/mirror/assets/mirror-ui.js?v=20261113h" | grep -i '^cache-control'
curl -sI "$B/assets/portal/portal.js" | grep -i '^cache-control'

echo "== git"
git status -sb | head -1
rm -rf "$T"
