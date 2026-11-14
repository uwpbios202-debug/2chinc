// Door codes for residents and owners (resident portal #keys, owner portal #keys).
// Shows only what the signed-in person may see: their building's shared codes and their own unit's codes.
// Database: supabase/migrations/20261112040000_keys_system.sql. Codes are data; none are in this repository.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

const CSS = `
.ky{display:grid;gap:14px}.ky-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.ky h2{margin:0 0 4px;font-size:1.15rem}.ky-sub{color:#5b6573;font-size:.88rem;margin:0}
.ky-code{font:700 1.9rem/1.2 ui-monospace,Consolas,monospace;letter-spacing:.14em;background:#eef6ec;border-radius:8px;padding:6px 14px;display:inline-block;margin:8px 0}
.ky-btn{background:none;border:1px solid #2e7d1f;color:#2e7d1f;border-radius:999px;padding:6px 14px;font-weight:700;cursor:pointer;margin-left:8px}
.ky-msg{color:#b3261e;font-size:.9rem}`;

const WHERE = (r) => r.building === "both" ? "Both buildings" : r.building + " N Bourbon St";

export async function mountKeys(el) {
  if (!document.getElementById("ky-css")) { const s = document.createElement("style"); s.id = "ky-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="ky-sub">Loading…</p>`;
  const { data, error } = await client.rpc("keys_mine");
  if (error) { el.innerHTML = `<p class="ky-msg">${esc(await errorText(error))}</p>`; return; }
  const rows = data || [];
  if (!rows.length) { el.innerHTML = `<p class="ky-sub">No door codes are on file for your home yet. Call the office and we will get them to you.</p>`; return; }
  el.innerHTML = `<div class="ky"><p class="ky-sub">These codes are for the people who live here. Please don't share them, and don't prop the doors open. If a code stops working, call the office.</p>
    ${rows.map((r, i) => `<div class="ky-card"><h2>${esc(r.name)}${r.unit ? ` · Unit ${esc(r.unit)}` : ""}</h2>
      <p class="ky-sub">${esc(WHERE(r))}${r.note ? " · " + esc(r.note) : ""}</p>
      <div><span class="ky-code" data-i="${i}">••••••</span><button class="ky-btn" type="button" data-show="${i}">Show</button></div>
      <p class="ky-sub">Updated ${fmtDate(String(r.updated_at).slice(0, 10))}</p></div>`).join("")}</div>`;
  el.onclick = (e) => {
    const b = e.target.closest("[data-show]"); if (!b) return;
    const span = el.querySelector(`.ky-code[data-i="${b.dataset.show}"]`), shown = b.textContent === "Hide";
    span.textContent = shown ? "••••••" : rows[Number(b.dataset.show)].code; b.textContent = shown ? "Show" : "Hide";
  };
}
