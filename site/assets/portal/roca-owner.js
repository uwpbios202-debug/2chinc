// ROCA1 owner portal: violations at your units (fine notices, request a hearing, decisions) and the monthly rent
// statements for units 2nd Chance leases for you (rent collected, what was paid to ROCA1 from it, fees, net to you).
//   mountOwnerViolations(el)  — Rules & Regulations 2024 §10: request a hearing in writing within 14 days of a fine notice
//   mountDistributions(el)    — statements approved by the office; printable
// Database: supabase/migrations/20261106080000_roca_violations_deductions.sql.
import { client, esc, fmtDate, money, errorText, todayCT } from "/assets/portal/portal.js";

const CSS = `
.ro{display:grid;gap:14px}.ro-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.ro h2{margin:0 0 6px;font-size:1.2rem}.ro-sub{color:#5b6573;font-size:.88rem;margin:0}
.ro-row{border-top:1px solid #eef1ec;padding:10px 0}
.ro-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.ro-pill.warn{background:#fff3cd;color:#7a5200}.ro-pill.off{background:#eee;color:#555}
.ro-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:9px 18px;font-weight:700;cursor:pointer}.ro-btn:disabled{opacity:.5}
.ro-link{background:none;border:0;color:#2e7d1f;font-weight:600;cursor:pointer;padding:0;text-decoration:underline}
.ro textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;width:100%;box-sizing:border-box;margin-top:6px}
.ro-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.ro-msg.err{color:#b3261e}.ro-msg.ok{color:#2e7d1f}
.ro table{width:100%;border-collapse:collapse;font-size:.92rem}.ro td,.ro th{padding:5px 6px;border-bottom:1px solid #eef1ec;text-align:left}.ro td.n,.ro th.n{text-align:right;white-space:nowrap}`;
const css = () => { if (!document.getElementById("ro-css")) { const s = document.createElement("style"); s.id = "ro-css"; s.textContent = CSS; document.head.appendChild(s); } };

const VST = { notice_sent: ["fine notice — you may appeal", "warn"], hearing_requested: ["hearing requested", "warn"], hearing_scheduled: ["hearing scheduled", "warn"],
  final: ["fine final", ""], fined: ["fined", ""], cured: ["cured", "off"], dismissed: ["dismissed", "off"], waived: ["waived", "off"], open: ["open", "warn"] };

export async function mountOwnerViolations(el) {
  css();
  el.innerHTML = `<p class="ro-sub">Loading…</p>`;
  const { data, error } = await client.rpc("roca_violations_mine");
  if (error) { el.innerHTML = `<p class="ro-msg err">${esc(await errorText(error))}</p>`; return; }
  const list = data.violations || [], today = todayCT();
  el.innerHTML = `<div class="ro"><div class="ro-card"><h2>Violations</h2>
    <p class="ro-sub">Notices of rule violations at your units (ROCA1 Rules &amp; Regulations §10). After a fine notice you have ${esc(data.appeal_days || "14")} days to request a hearing in writing; a timely request suspends the fine until the board hears it. Fines are charged to your association account.</p>
    ${list.length ? list.map((v) => {
      const [lbl, cls] = VST[v.status] || [v.status, ""], f = v.schedule || {};
      const canAppeal = v.status === "notice_sent" && v.process === "fine_notice" && v.appeal_deadline >= today;
      return `<div class="ro-row"><div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap"><b>Unit ${esc(v.unit)} · ${esc(f.title || v.category)}</b><span class="ro-pill ${cls}">${esc(lbl)}</span></div>
        <div>${esc(v.description)}</div>
        <div class="ro-sub">${esc(f.section || "")} · observed ${fmtDate(v.observed_date)} · fine ${money(v.fine_amount != null ? v.fine_amount : f.amount)}${f.amount_note ? " — " + esc(f.amount_note) : ""}${Number(v.charged) ? " · charged " + money(v.charged) : ""}</div>
        ${canAppeal ? `<div class="ro-sub">Request a hearing by <b>${fmtDate(v.appeal_deadline)}</b>.</div>
          <details><summary class="ro-link">Request a hearing</summary><textarea rows="3" maxlength="2000" data-note="${v.id}" placeholder="Why you dispute it. This is your written request."></textarea>
          <label class="ro-sub" style="display:block;margin-top:6px">Photos or a PDF that support you (optional, up to 3, 10 MB each)<input type="file" data-ev="${v.id}" accept="image/jpeg,image/png,image/webp,image/heic,.heic,application/pdf" multiple style="display:block;margin-top:4px"></label>
          <button class="ro-btn" type="button" data-hear="${v.id}">Send my request</button><div class="ro-msg" data-msg="${v.id}"></div></details>` : ""}
        ${v.hearing_requested_at ? `<div class="ro-sub">You requested a hearing ${fmtDate(v.hearing_requested_at)}${(v.hearing_evidence || []).length ? ` with ${v.hearing_evidence.length} attached file${v.hearing_evidence.length > 1 ? "s" : ""}` : ""}.</div>` : ""}
        ${v.hearing_at ? `<div class="ro-sub">Hearing: ${new Date(v.hearing_at).toLocaleString("en-US", { dateStyle: "full", timeStyle: "short" })} · ${esc(v.hearing_place || "")}. Written decision by ${fmtDate(v.decision_due)}.</div>` : ""}
        ${v.decision_note ? `<div class="ro-sub">${esc(v.decision_note)}</div>` : ""}</div>`;
    }).join("") : `<p class="ro-sub" style="margin-top:8px">No violation notices for your units.</p>`}</div></div>`;
  el.querySelectorAll("[data-hear]").forEach((b) => b.onclick = async () => {
    const id = b.dataset.hear, msg = el.querySelector(`[data-msg="${id}"]`);
    b.disabled = true;
    const paths = [], files = [...el.querySelector(`[data-ev="${id}"]`).files], typeOf = (f) => f.type || (/.heic$/i.test(f.name) ? "image/heic" : "");
    try {
      if (files.length > 3) throw new Error("Please attach 3 files or fewer.");
      for (const f of files) {
        if (!["image/jpeg", "image/png", "image/webp", "image/heic", "application/pdf"].includes(typeOf(f))) throw new Error(`"${f.name}" isn't a JPG, PNG, WebP, HEIC or PDF file.`);
        if (f.size > 10 * 1024 * 1024) throw new Error(`"${f.name}" is over 10 MB.`);
      }
      if (files.length) {
        const { data: me, error: meErr } = await client.rpc("owner_my_id");
        if (meErr || !me) throw new Error("Could not start the upload. Reload and try again.");
        for (const f of files) {
          const type = typeOf(f), path = `${me}/${id}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${type === "application/pdf" ? "pdf" : type.split("/")[1].replace("jpeg", "jpg")}`;
          const { error: uErr } = await client.storage.from("violation-evidence").upload(path, f, { contentType: type });
          if (uErr) throw new Error(`"${f.name}" couldn't be uploaded. Check your connection and try again.`);
          paths.push(path);
        }
      }
    } catch (err) { msg.className = "ro-msg err"; msg.textContent = err.message; b.disabled = false; return; }
    const { error: e } = await client.rpc("roca_violation_request_hearing", { p_id: Number(id), p_note: el.querySelector(`[data-note="${id}"]`).value, p_evidence: paths });
    if (e) { msg.className = "ro-msg err"; msg.textContent = await errorText(e); b.disabled = false; return; }
    client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
    mountOwnerViolations(el);
  });
}

const CAT = { fines_fees: "Fines & fees", assessments: "Special assessments", dues_current: "Association dues (this month)", older_balance: "Past-due association dues" };

function statementHtml(d) {
  const line = (l, a, b) => `<tr><td>${l}</td><td class="n">${b ? "<b>" : ""}${money(a)}${b ? "</b>" : ""}</td></tr>`;
  return `<h2 style="margin:0">Unit ${esc(d.unit_number)} — ${esc(d.month_label)}</h2>
    <p class="ro-sub">${esc(d.owner_name || "")} · prepared by 2nd Chance Housing Inc. as manager · ${esc(d.status === "paid" ? "paid" : d.status === "transferred" ? "paid to ROCA1" : "approved")}</p>
    <table><tbody>
      ${line("Rent collected from the tenant", d.rent_collected)}${Number(d.agency_collected) ? line("Housing assistance paid by the agency", d.agency_collected) : ""}
      ${(d.deductions || []).map((x) => line("Paid to ROCA1: " + esc(CAT[x.category] || x.category), -x.amount)).join("")}
      ${Number(d.mgmt_fee) ? line("Management fee (your management agreement)", -d.mgmt_fee) : ""}${Number(d.card_fee) ? line("Card collection fee", -d.card_fee) : ""}
      ${(d.other_deductions || []).map((x) => line(esc(x.label), -x.amount)).join("")}
      ${Number(d.reserve_held) ? line("Kept as operating reserve", -d.reserve_held) : ""}
      ${line("Net to you", d.net_to_owner, true)}
    </tbody></table>
    ${Number(d.shortfall) ? `<p class="ro-sub">Your association account still owed ${money(d.shortfall)} after this statement.</p>` : ""}
    ${d.transfer_date ? `<p class="ro-sub">Paid to ROCA1 ${fmtDate(d.transfer_date)} (ref ${esc(d.transfer_reference || "")}).${d.paid_date && !d.owner_is_2ch ? ` Paid to you ${fmtDate(d.paid_date)}${d.paid_method ? " by " + esc(d.paid_method) : ""}.` : ""}</p>` : ""}
    <p class="ro-sub">Fines and fees are paid first (ROCA1 Rules &amp; Regulations §11). Property taxes are not paid from rent.</p>`;
}

export async function mountDistributions(el) {
  css();
  el.innerHTML = `<p class="ro-sub">Loading…</p>`;
  const { data, error } = await client.rpc("roca_distributions_mine");
  if (error) { el.innerHTML = `<p class="ro-msg err">${esc(await errorText(error))}</p>`; return; }
  const list = data || [];
  // A unit whose tenant pays rent straight into ROCA1's account: pending payments and what happened to each cleared one.
  const { data: rp } = await client.rpc("roca_rent_pending_mine");
  const routed = (rp || []).map((u) => `<div class="ro-card"><h2>Unit ${esc(u.unit_number)}: your tenant's rent</h2>
    ${(u.pending || []).length ? `<p class="ro-sub"><b>Pending:</b> ${u.pending.map((p) => `${money(p.amount)} (${esc(p.how)}, ${fmtDate(p.date)})`).join("; ")}. Your association account is paused while it clears: no late fee or interest. When it clears, what you owe ROCA1 is taken out of it and the rest is sent to you.</p>` : `<p class="ro-sub">No rent payment is pending.</p>`}
    ${(u.recent || []).length ? `<table><thead><tr><th>Paid</th><th class="n">Rent</th><th class="n">To ROCA1 (your account)</th><th class="n">To you</th><th>Sent to you</th></tr></thead><tbody>
      ${u.recent.map((r) => `<tr><td>${fmtDate(r.paid_on)}</td><td class="n">${money(r.rent_amount)}</td><td class="n">${money(r.to_roca1)}${(r.deductions || []).map((x) => `<div class="ro-sub">${esc(CAT[x.category] || x.category)} ${money(x.amount)}</div>`).join("")}</td>
        <td class="n"><b>${money(r.net_to_owner)}</b></td><td>${r.status === "sent" ? (r.payout_method === "withdraw" ? "Withdrawn " : r.payout_method === "check" ? "Check mailed " : "Zelle sent ") + fmtDate(r.sent_date) : r.status === "zelle_due" ? (r.payout_method === "withdraw" ? "Ready to withdraw at the bank" : r.payout_method === "check" ? "Check being mailed" : "Being sent") : r.status === "reversed" ? "Payment reversed" : "Nothing to send"}</td></tr>`).join("")}</tbody></table>` : ""}</div>`).join("");
  el.innerHTML = (routed ? `<div class="ro">${routed}</div>` : "") + `<div class="ro"><div class="ro-card"><h2>Rent statements</h2>
    <p class="ro-sub">For a unit 2nd Chance Housing leases for you: each month's rent collected, what was paid to ROCA1 out of it for your association account, any fee in your management agreement, and the net to you.</p>
    ${list.length ? `<table><thead><tr><th>Month</th><th>Unit</th><th class="n">Rent</th><th class="n">To ROCA1</th><th class="n">Net to you</th><th></th></tr></thead><tbody>
      ${list.map((d, i) => `<tr><td>${esc(d.month_label)}</td><td>${esc(d.unit_number)}</td><td class="n">${money(Number(d.rent_collected) + Number(d.agency_collected))}</td><td class="n">${money(d.deduction_total)}</td>
        <td class="n"><b>${money(d.net_to_owner)}</b></td><td><button class="ro-link" type="button" data-show="${i}">View</button> · <button class="ro-link" type="button" data-print="${i}">Print</button></td></tr>`).join("")}
      </tbody></table><div id="roStmt" style="margin-top:12px"></div>` : `<p class="ro-sub" style="margin-top:8px">No statements yet.</p>`}</div></div>`;
  el.querySelectorAll("[data-show]").forEach((b) => b.onclick = () => { el.querySelector("#roStmt").innerHTML = `<div class="ro-card">${statementHtml(list[Number(b.dataset.show)])}</div>`; });
  el.querySelectorAll("[data-print]").forEach((b) => b.onclick = () => {
    const d = list[Number(b.dataset.print)], w = window.open("", "_blank");
    if (!w) return;
    w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Unit ${esc(d.unit_number)} statement ${esc(d.month_label)}</title><style>${CSS}
      body{font-family:"Source Sans 3",Arial,sans-serif;margin:32px;color:#1b2430}</style></head><body class="ro">
      <p style="margin:0;font-weight:700">2nd Chance Housing Inc. · 6626 N. Bourbon St., Milwaukee, WI 53224</p>
      <p class="ro-sub" style="margin:0 0 18px">Manager for Royal Orleans Condominium Association – Addition 1 (ROCA1) units</p>${statementHtml(d)}</body></html>`);
    w.document.close(); w.focus(); w.print();
  });
}
