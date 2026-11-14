// Household members for tenants (resident portal #household).
// Everyone living in the unit who doesn't sign the lease. The tenant adds someone and the office approves it; the tenant
// reports when someone moves out. Shows people living there against the unit's limit (Milwaukee bedroom-size rule).
// Database: supabase/migrations/20261106020000_household_disputes.sql.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

const CSS = `
.hh{display:grid;gap:14px}.hh-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.hh h2{margin:0 0 6px;font-size:1.2rem}.hh-sub{color:#5b6573;font-size:.88rem;margin:0}
.hh-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-top:10px}
.hh-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}.hh-form .wide{grid-column:1/-1}
.hh-form input,.hh-form select,.hh-form textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.hh-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:10px 20px;font-weight:700;cursor:pointer}.hh-btn:disabled{opacity:.5}
.hh-link{background:none;border:0;color:#2e7d1f;font-weight:600;cursor:pointer;padding:0;text-decoration:underline}
.hh-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.hh-pill.pending{background:#fff3cd;color:#7a5200}.hh-pill.declined,.hh-pill.removed{background:#eee;color:#555}
.hh-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.hh-msg.err{color:#b3261e}.hh-msg.ok{color:#2e7d1f}
.hh-row{border-top:1px solid #eef1ec;padding:10px 0}
.hh-count{font-size:1.05rem}.hh-warn{background:#fff3cd;border-radius:8px;padding:8px 10px;font-size:.88rem;color:#5c3d00;margin-top:8px}`;

const STATUS = { pending: "waiting for the office", approved: "living here", declined: "declined", removed: "moved out" };

export async function mountHousehold(el) {
  if (!document.getElementById("hh-css")) { const s = document.createElement("style"); s.id = "hh-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="hh-sub">Loading…</p>`;
  const { data, error } = await client.rpc("household_mine");
  if (error) { el.innerHTML = `<p class="hh-msg err">${esc(await errorText(error))}</p>`; return; }
  const leases = data.leases || [], today = new Date().toISOString().slice(0, 10);
  if (!leases.length) { el.innerHTML = `<p class="hh-sub">The household list is for current tenants.</p>`; return; }
  el.innerHTML = `<div class="hh">${leases.map((l, i) => {
    const pending = l.members.filter((m) => m.status === "pending").length;
    const over = l.limit && l.people + pending > l.limit;
    return `<div class="hh-card"><h2>Who lives in Unit ${esc(l.unit)}</h2>
      <p class="hh-count"><b>${l.people}</b> ${l.people === 1 ? "person" : "people"} living here${l.limit ? ` · up to <b>${l.limit}</b> allowed` : ""}</p>
      <p class="hh-sub">On the lease: ${l.signers.map(esc).join(", ") || "—"}. Everyone else who lives here goes on this list, including children. The office approves each new person. Guests who stay overnight are not household members — use Guest requests for them.</p>
      ${over ? `<div class="hh-warn">With the people waiting for approval, the unit would be over its limit of ${l.limit}. The office will contact you.</div>` : ""}
      ${l.members.length ? l.members.map((m) => `<div class="hh-row"><div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap">
          <b>${esc(m.name)}${m.relationship ? ` <span class="hh-sub">(${esc(m.relationship)})</span>` : ""}</b><span class="hh-pill ${esc(m.status)}">${esc(STATUS[m.status] || m.status)}</span></div>
        <div class="hh-sub">${m.age != null ? (m.minor ? "Child, age " + m.age : "Adult") : ""}${m.moved_in ? ` · moved in ${fmtDate(m.moved_in)}` : ""}${m.moved_out ? ` · moved out ${fmtDate(m.moved_out)}` : ""}</div>
        ${m.status === "declined" && m.staff_note ? `<div class="hh-sub">Office: ${esc(m.staff_note)}</div>` : ""}
        ${m.status === "pending" ? `<button class="hh-link" type="button" data-hhcancel="${esc(m.id)}">Cancel this request</button>` : ""}
        ${m.status === "approved" && !m.moved_out ? `<div class="hh-form" style="margin-top:4px;grid-template-columns:auto auto 1fr;align-items:end">
          <label>Moved out on<input type="date" data-hhout="${esc(m.id)}" value="${today}"></label><button class="hh-link" type="button" data-hhgone="${esc(m.id)}">They moved out</button><span></span></div>` : ""}
      </div>`).join("") : `<p class="hh-sub" style="margin-top:8px">Nobody else is listed yet.</p>`}
      <form class="hh-form" data-hhform="${i}" novalidate>
        <div class="wide"><b>Add someone who lives here</b></div>
        <label>Full name<input name="name" autocomplete="off" required></label>
        <label>Relationship to you<select name="rel"><option>Child</option><option>Spouse / partner</option><option>Parent</option><option>Brother / sister</option><option>Grandchild</option><option>Other relative</option><option>Other</option></select></label>
        <label>Date of birth<input name="dob" type="date" max="${today}"></label>
        <label>Moving in (or moved in)<input name="in" type="date" value="${today}"></label>
        <label class="wide">Anything we should know? (optional)<textarea name="note" rows="2" maxlength="500"></textarea></label>
        <div class="wide"><button class="hh-btn" type="submit">Send to the office</button><div class="hh-msg" role="status"></div></div>
      </form></div>`;
  }).join("")}</div>`;

  el.querySelectorAll("[data-hhform]").forEach((f) => f.onsubmit = async (e) => {
    e.preventDefault();
    const l = leases[+f.dataset.hhform], msg = f.querySelector(".hh-msg"), btn = f.querySelector("button");
    const v = (n) => f.elements[n].value.trim();
    btn.disabled = true; msg.className = "hh-msg"; msg.textContent = "Sending…";
    const { error: err } = await client.rpc("household_add", { p_lease: l.lease_id, p_name: v("name"), p_relationship: v("rel"), p_birth: v("dob") || null, p_moved_in: v("in") || null, p_note: v("note") });
    if (err) { btn.disabled = false; msg.className = "hh-msg err"; msg.textContent = await errorText(err); return; }
    client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
    await mountHousehold(el);
  });
  el.querySelectorAll("[data-hhcancel]").forEach((b) => b.onclick = async () => {
    if (!confirm("Cancel this request?")) return;
    const { error: err } = await client.rpc("household_remove", { p_id: b.dataset.hhcancel, p_moved_out: null });
    if (err) return alert(await errorText(err));
    mountHousehold(el);
  });
  el.querySelectorAll("[data-hhgone]").forEach((b) => b.onclick = async () => {
    const d = el.querySelector(`[data-hhout="${b.dataset.hhgone}"]`).value;
    if (!d) return alert("Enter the day they moved out.");
    if (!confirm("Take this person off your household list?")) return;
    const { error: err } = await client.rpc("household_remove", { p_id: b.dataset.hhgone, p_moved_out: d });
    if (err) return alert(await errorText(err));
    client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
    mountHousehold(el);
  });
}
