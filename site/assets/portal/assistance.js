// Housing assistance for tenants (resident portal, Payments page): how the rent is split between the tenant and an
// agency (a voucher or another program). Shows nothing when no agency pays part of the rent.
// Database: supabase/migrations/20261106010000_housing_assistance.sql (assistance_mine).
import { client, esc, fmtDate, money, errorText } from "/assets/portal/portal.js";

const CSS = `
.ha-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.ha-card h2{margin:0 0 6px;font-size:1.2rem}.ha-sub{color:#5b6573;font-size:.88rem;margin:0}
.ha-split{display:grid;grid-template-columns:1fr auto;gap:4px 16px;margin:10px 0;max-width:380px}
.ha-split .n{text-align:right;font-variant-numeric:tabular-nums}.ha-split .tot{border-top:1px solid #d9dfd6;padding-top:4px;font-weight:700}
.ha-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#eee;color:#555}
.ha-msg.err{color:#b3261e;font-size:.9rem}`;

export async function mountAssistance(el, opts = {}) {
  if (!document.getElementById("ha-css")) { const s = document.createElement("style"); s.id = "ha-css"; s.textContent = CSS; document.head.appendChild(s); }
  const { data, error } = await client.rpc("assistance_mine");
  if (error) { el.innerHTML = opts.quietErrors ? "" : `<p class="ha-msg err">${esc(await errorText(error))}</p>`; return []; }
  const rows = (data || []).filter((r) => !opts.leaseId || r.lease_id === opts.leaseId);
  if (!rows.length) { el.innerHTML = ""; return rows; }
  el.innerHTML = rows.map((r) => r.status === "active" ? `<div class="ha-card"><h2>Your rent and housing assistance</h2>
      <p class="ha-sub">${esc(r.agency)} (${esc(r.program)}) pays part of your rent${rows.length > 1 && r.unit ? " for Unit " + esc(r.unit) : ""}, starting ${fmtDate(r.start_date)}${r.end_date ? " through " + fmtDate(r.end_date) : ""}.</p>
      <div class="ha-split"><span>Monthly rent</span><span class="n">${money(r.rent)}</span>
        <span>Paid by ${esc(r.agency)}</span><span class="n">−${money(r.agency_portion)}</span>
        <span class="tot">Your portion each month</span><span class="n tot">${money(r.your_portion)}</span></div>
      <p class="ha-sub">Your balance and any late fee count only your portion. On your history, each rent charge has a matching "Housing assistance" line for the agency's share. If the agency changes your portion, tell the office${r.agency_phone ? `, and call ${esc(r.agency)} at ${esc(r.agency_phone)} with questions about your voucher` : ""}.</p></div>`
    : `<div class="ha-card"><h2>Housing assistance <span class="ha-pill">ended</span></h2>
      <p class="ha-sub">${esc(r.agency)} paid ${money(r.agency_portion)} a month of your rent from ${fmtDate(r.start_date)} to ${fmtDate(r.end_date)}.</p></div>`).join("");
  return rows;
}
