#!/bin/sh
# T6.1 Remove link: stubbed copy of the needs page driven in headless Chrome, then removed.
set -eu
cd "$(dirname "$0")/.."
t=site/mirror/_t61c
mkdir -p "$t"
cat > "$t/stub.js" <<'EOF'
let needs = [
  { id: "n1", dimension: "housing", dimension_title: "Housing", category: "general", private: false, title: "A place of my own", detail: null, urgency: "urgent", status: "planning", last_change: null },
  { id: "n2", dimension: "physical_health", dimension_title: "My body", category: "health", private: true, title: "Dentist", detail: null, urgency: "soon", status: "identified", last_change: null }];
window.__calls = [];
export async function requireArea() { return { memberships: [] }; }
export async function rpc(name, a = {}) {
  window.__calls.push([name, a]);
  if (name === "mirror_needs_list") return { self: true, can_add: ["general"], needs: JSON.parse(JSON.stringify(needs)) };
  if (name === "mirror_need_suggestions") return [];
  if (name === "mirror_need_delete") { needs = needs.filter((n) => n.id !== a.p_id); return true; }
  throw new Error("unexpected " + name);
}
EOF
cat > "$t/drive.js" <<'EOF'
const out = [], errs = [];
window.addEventListener("error", (e) => errs.push(e.message));
window.addEventListener("unhandledrejection", (e) => errs.push(String(e.reason)));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  await wait(700);
  const q = (s) => document.querySelector(s);
  out.push("1 load: needs=" + document.querySelectorAll("[data-need]").length + " remove-links=" + document.querySelectorAll("[data-del]").length);
  q('[data-need="n2"] [data-del]').click(); await wait(50);
  out.push("2 confirm shown: " + /Remove "Dentist" for good/.test(q('[data-need="n2"]').textContent));
  q('[data-need="n2"] [data-no]').click(); await wait(50);
  out.push("3 keep: still there=" + !!q('[data-need="n2"]') + " calls=" + window.__calls.filter((c) => c[0] === "mirror_need_delete").length);
  q('[data-need="n2"] [data-del]').click(); await wait(50);
  q('[data-need="n2"] [data-yes]').click(); await wait(400);
  out.push("4 removed: call=" + JSON.stringify(window.__calls.filter((c) => c[0] === "mirror_need_delete").pop()) + " needs=" + document.querySelectorAll("[data-need]").length);
  out.push("errors=" + JSON.stringify(errs));
  const pre = document.createElement("pre"); pre.id = "OUT"; pre.textContent = out.join("\n"); document.body.append(pre);
})();
EOF
sed -e 's|/mirror/assets/mirror-client.js?v=20261113d|/mirror/_t61c/stub.js|' -e 's|</body>|<script type="module" src="/mirror/_t61c/drive.js"></script></body>|' \
  site/mirror/my-mirror/my-needs/index.html > "$t/index.html"
"/c/Program Files/Google/Chrome/Application/chrome.exe" --headless=new --disable-gpu --no-first-run --user-data-dir="$TEMP/t61cprof" \
  --virtual-time-budget=6000 --dump-dom "http://127.0.0.1:8787/mirror/_t61c/" 2>/dev/null | sed -n '/<pre id="OUT">/,/<\/pre>/p'
rm -rf "$t"
