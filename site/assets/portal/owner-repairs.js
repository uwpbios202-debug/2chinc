// Owner portal #repairs: tenant repair requests in the owner's units (units in portal setting repair_owner_cc_units).
// Where the owner is responsible (repair_owner_handles_units, e.g. Unit 16) they post updates and mark it in progress or done;
// the tenant and the office are emailed. Database: supabase/migrations/20261118230000_repair_owner_copy.sql.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

const CSS = `
.rp{display:grid;gap:14px}.rp-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.rp h3{margin:0 0 4px;font-size:1.05rem}.rp-sub{color:#5b6573;font-size:.88rem;margin:0}
.rp-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f;margin-left:6px}
.rp-pill.new{background:#fff3cd;color:#7a5200}.rp-pill.closed{background:#eee;color:#555}
.rp-upd{border-left:3px solid #d9dfd6;margin:6px 0 0 4px;padding:2px 10px;font-size:.88rem}
.rp-form{display:grid;gap:8px;margin-top:10px;border-top:1px solid #eef1ec;padding-top:10px}
.rp-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}
.rp-form select,.rp-form textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.rp-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:10px 20px;font-weight:700;cursor:pointer;justify-self:start}.rp-btn:disabled{opacity:.5}
.rp-msg{min-height:1.2em;font-size:.9rem}.rp-msg.err{color:#b3261e}.rp-msg.ok{color:#2e7d1f}
.rp-you{background:#fff3cd;border-radius:8px;padding:8px 10px;font-size:.9rem;color:#5c3d00}`;

const ENTRY = { yes: "Yes, may enter", no: "No, only when home", call_first: "Call first" };
const dt = (s) => s ? new Date(s).toLocaleString("en-US", { timeZone: "America/Chicago", month: "numeric", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }) : "";

// True when the owner has at least one unit whose repairs they are copied on (shows the Repairs tab).
export async function ownerHasRepairs() {
  const { data, error } = await client.rpc("owner_repairs_mine");
  return !error && (data?.units || []).length > 0;
}

export async function mountOwnerRepairs(el) {
  if (!document.getElementById("rp-css")) { const s = document.createElement("style"); s.id = "rp-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="rp-sub">Loading…</p>`;
  const { data: D, error } = await client.rpc("owner_repairs_mine");
  if (error) { el.innerHTML = `<p class="rp-msg err">${esc(await errorText(error))}</p>`; return; }
  const units = D.units || [], reqs = D.requests || [];
  if (!units.length) { el.innerHTML = ""; return; }   // e.g. Unit 7: only the HVAC card applies
  const mine = units.filter((u) => u.handles).map((u) => u.unit), copied = units.filter((u) => !u.handles).map((u) => u.unit);
  el.innerHTML = `<div class="rp">
    ${mine.length ? `<div class="rp-you"><b>You are responsible for repairs in Unit ${mine.map(esc).join(", ")}.</b> When your tenant sends a request you get an email. Arrange the repair, then post each update here and mark it done. Your tenant and our office get every update by email. For an emergency, also call the office at (262) 236-5443.</div>` : ""}
    ${copied.length ? `<p class="rp-sub">2nd Chance handles repairs in Unit ${copied.map(esc).join(", ")}. You get a copy of every message so you can follow along; you don't need to do anything.</p>` : ""}
    ${reqs.length ? reqs.map(card).join("") : `<div class="rp-card"><p class="rp-sub">No repair requests from your tenants yet.</p></div>`}</div>`;

  el.querySelectorAll("[data-rpsend]").forEach((btn) => btn.onclick = async () => {
    const box = btn.closest("[data-rpid]"), m = box.querySelector(".rp-msg");
    const status = box.querySelector("[data-rpstatus]").value || null, note = box.querySelector("[data-rpnote]").value.trim();
    if (!status && note.length < 2) { m.className = "rp-msg err"; m.textContent = "Write an update or choose a new status."; return; }
    btn.disabled = true; m.className = "rp-msg"; m.textContent = "Sending…";
    const { error: e } = await client.rpc("owner_repair_update", { p_id: box.dataset.rpid, p_status: status, p_note: note || null });
    btn.disabled = false;
    if (e) { m.className = "rp-msg err"; m.textContent = await errorText(e); return; }
    await client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});   // emails the tenant and the office right away
    mountOwnerRepairs(el);
  });
}

function card(r) {
  const open = r.status !== "closed";
  return `<div class="rp-card" data-rpid="${esc(r.id)}">
    <h3>Unit ${esc(r.unit)} · #${esc(r.number)} ${esc(r.subject)}<span class="rp-pill ${esc(r.status)}">${esc(r.status_label)}</span></h3>
    <p class="rp-sub">${esc(r.category)} · sent ${fmtDate(r.created_at)} · permission to enter: ${esc(ENTRY[r.entry] || r.entry)} · animals: ${r.has_pets ? esc(r.pets_note || "yes") : "none"}${r.photos ? ` · ${r.photos} photo(s) (ask the office)` : ""}</p>
    ${r.scheduled_start ? `<p class="rp-sub">Scheduled: ${esc(dt(r.scheduled_start))}</p>` : ""}
    <p style="margin:8px 0 0;white-space:pre-wrap">${esc(r.description)}</p>
    ${(r.updates || []).map((u) => `<div class="rp-upd"><b>${esc(u.by)}</b> · ${esc(dt(u.at))}${u.status_label ? ` · <b>${esc(u.status_label)}</b>` : ""}${u.note ? `<br>${esc(u.note)}` : ""}</div>`).join("")}
    ${r.handles && open ? `<div class="rp-form">
      <label>New status (optional)<select data-rpstatus><option value="">No change</option><option value="in_progress">In progress</option><option value="completed">Done (the tenant is asked to confirm)</option></select></label>
      <label>Update for your tenant and the office<textarea data-rpnote rows="3" maxlength="2000" placeholder="e.g. A plumber is coming Thursday between 9 and 11."></textarea></label>
      <button class="rp-btn" type="button" data-rpsend>Send update</button><div class="rp-msg" role="status"></div></div>` : ""}
  </div>`;
}
