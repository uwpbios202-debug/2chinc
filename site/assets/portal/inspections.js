// Upcoming unit inspections for tenants (resident portal). Shows each booked inspection of the tenant's unit
// once they have been told about it (the 12-hour notice to enter, or a confirmation of an entry they agreed to),
// plus cancellations and inspections finished in the last 7 days. The notice itself is in Documents > Notices.
// Database: supabase/migrations/20261106030000_periodic_inspections.sql (resident_inspection_appointments).
import { client, esc, errorText } from "/assets/portal/portal.js";

const CSS = `
.iq{display:grid;gap:10px}.iq-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.iq h2{margin:0 0 6px;font-size:1.2rem}.iq-sub{color:#5b6573;font-size:.88rem;margin:0}
.iq-row{border-top:1px solid #eef1ec;padding:10px 0}.iq-row:first-of-type{border-top:0}
.iq-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#fff3cd;color:#7a5200}
.iq-pill.done{background:#e7f3e3;color:#2e7d1f}.iq-pill.cancelled{background:#eee;color:#555}
.iq-msg.err{color:#b3261e;font-size:.9rem}`;

// opts.hideWhenEmpty: render nothing (and return false) when there is nothing to show — for a dashboard box.
export async function mountInspectionNotices(el, opts = {}) {
  if (!document.getElementById("iq-css")) { const s = document.createElement("style"); s.id = "iq-css"; s.textContent = CSS; document.head.appendChild(s); }
  const { data, error } = await client.rpc("resident_inspection_appointments");
  if (error) { el.innerHTML = opts.hideWhenEmpty ? "" : `<p class="iq-msg err">${esc(await errorText(error))}</p>`; return false; }
  const list = data.appointments || [];
  if (!list.length) {
    el.innerHTML = opts.hideWhenEmpty ? "" : `<div class="iq-card"><h2>Unit inspections</h2><p class="iq-sub">No inspection of your unit is scheduled.</p></div>`;
    return !opts.hideWhenEmpty;
  }
  el.innerHTML = `<div class="iq"><div class="iq-card"><h2>🔍 Unit inspection${list.length > 1 ? "s" : ""}</h2>
    ${list.map((a) => `<div class="iq-row">
      <div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap"><b>${esc(a.purpose_label)} · Unit ${esc(a.unit)}</b>
        <span class="iq-pill ${esc(a.status)}">${a.status === "scheduled" ? "scheduled" : a.status === "done" ? "done" : "cancelled"}</span></div>
      <div>${esc(a.window)}</div>
      ${a.note ? `<div class="iq-sub">${esc(a.note)}</div>` : ""}
      <div class="iq-sub">${a.status === "cancelled" ? "Cancelled — we won't enter for it." + (a.cancelled_reason ? " (" + esc(a.cancelled_reason) + ")" : "")
        : a.entry_basis === "notice" ? "This is your 12-hour notice to enter; the notice is in Documents › Notices. You don't have to be home, and you may stay if you are."
        : "You agreed to this entry."}</div>
    </div>`).join("")}
    <p class="iq-sub" style="margin-top:8px">Questions, or want us to come earlier? Call ${esc(data.office_phone || "the office")}.</p></div></div>`;
  return true;
}
