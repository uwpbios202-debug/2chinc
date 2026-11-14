// Printable reports: one renderer for every report JSON from supabase/migrations/20261106040000_reports.sql
// ({ title, entity, source, period, columns, rows, group_by?, totals, notes }), used by the staff Reports page
// (site/accounting/reports/), the owner portal (mountOwnerReports) and the resident portal (mountTenantReports).
// Print uses a hidden #printArea (body.printing hides the rest of the page), like statement.js.
import { client, esc, fmtDate, money, errorText } from "/assets/portal/portal.js";
import { printStatement, STATEMENT_CSS } from "/assets/portal/statement.js";

const CSS = `
#printArea{display:none}
.rp{font-size:13px;color:#000;background:#fff}
.rp .rp-head{display:flex;justify-content:space-between;gap:20px;align-items:flex-start;margin-bottom:10px}
.rp table{width:100%;border-collapse:collapse}
.rp th,.rp td{border-bottom:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top}
.rp thead th{border-bottom:2px solid #000;font-size:12px}
.rp .n{text-align:right;white-space:nowrap}
.rp tr.sub td{font-weight:700;background:#f3f5f1;border-bottom:1px solid #999}
.rp tr.tot td{font-weight:700;border-top:2px solid #000;border-bottom:2px solid #000}
.rp .rp-notes{margin-top:10px;font-size:11px;color:#444}
.rp .rp-notes p{margin:2px 0}
.rq{display:grid;gap:14px;grid-template-columns:minmax(0,1fr)}.rq-view{overflow-x:auto}.rq-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.rq h2{margin:0 0 6px;font-size:1.2rem}.rq-sub{color:#5b6573;font-size:.88rem;margin:0}
.rq-form{display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin-top:10px}
.rq-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}
.rq-form input,.rq-form select{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff}
.rq-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:9px 18px;font-weight:700;cursor:pointer}
.rq-btn.ghost{background:#fff;color:#2e7d1f;border:1px solid #2e7d1f}
.rq-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.rq-msg.err{color:#b3261e}
.rq-view{overflow-x:auto;margin-top:10px}
@media print{
  body.printing>*:not(#printArea){display:none!important}
  body.printing #printArea{display:block}
  body.printing{background:#fff}
  .rp thead{display:table-header-group}
  .rp tr{page-break-inside:avoid}
}`;

export function ensureReportCss() {
  if (!document.getElementById("rp-css")) { const s = document.createElement("style"); s.id = "rp-css"; s.textContent = CSS + STATEMENT_CSS; document.head.appendChild(s); }
}

const cell = (c, v) => {
  if (v == null || v === "") return "";
  if (c.type === "money") return money(v);
  if (c.type === "date") return fmtDate(v);
  return esc(v);
};
const periodText = (p) => !p ? "" : p.as_of ? "As of " + fmtDate(p.as_of) : (fmtDate(p.from) + " – " + fmtDate(p.to));

// The report as an HTML table, with subtotals per group_by and a grand total row.
export function reportHtml(r) {
  const cols = r.columns || [], rows = r.rows || [], g = r.group_by, money_ = cols.filter((c) => c.type === "money");
  const sumRow = (rs) => Object.fromEntries(money_.map((c) => [c.key, rs.reduce((t, x) => t + Number(x[c.key] || 0), 0)]));
  const tr = (x, cls = "") => `<tr${cls ? ` class="${cls}"` : ""}>${cols.map((c) => `<td${c.type === "money" || c.type === "int" ? ' class="n"' : ""}>${cell(c, x[c.key])}</td>`).join("")}</tr>`;
  let body = "";
  if (g && rows.length) {
    let i = 0;
    while (i < rows.length) {
      const k = rows[i][g], grp = [];
      while (i < rows.length && rows[i][g] === k) grp.push(rows[i++]);
      body += grp.map((x) => tr(x)).join("");
      if (money_.length) body += tr({ ...sumRow(grp), [cols[0].key]: (cols[0].key === g ? k + " — " : "") + "Subtotal" }, "sub");
    }
  } else body = rows.map((x) => tr(x)).join("");
  const tot = money_.length && rows.length ? tr({ ...r.totals, [cols[0].key]: "Total" }, "tot") : "";
  const who = r.owner || r.tenant;
  return `<div class="rp">
    <div class="rp-head"><div><b>${esc(r.entity || "")}</b>${who ? `<br>${esc(who)}` : ""}</div>
      <div style="text-align:right"><b style="font-size:1.25em">${esc(r.title || "")}</b><br>${esc(periodText(r.period))}<br>Printed ${fmtDate(new Date().toISOString())}</div></div>
    ${rows.length ? `<table><thead><tr>${cols.map((c) => `<th${c.type === "money" || c.type === "int" ? ' class="n"' : ""}>${esc(c.label)}</th>`).join("")}</tr></thead><tbody>${body}${tot}</tbody></table>`
      : `<p>Nothing to report for this period.</p>`}
    <div class="rp-notes"><p>Source: ${esc(r.source || "")}.</p>${(r.notes || []).filter(Boolean).map((n) => `<p>${esc(n)}</p>`).join("")}</div>
  </div>`;
}

export function printHtml(html) {
  ensureReportCss();
  let area = document.getElementById("printArea");
  if (!area) { area = document.createElement("div"); area.id = "printArea"; document.body.appendChild(area); }
  area.innerHTML = html;
  document.body.classList.add("printing");
  const done = () => { document.body.classList.remove("printing"); window.removeEventListener("afterprint", done); };
  window.addEventListener("afterprint", done);
  window.print();
}
export const printReport = (r) => printHtml(reportHtml(r));

const csvCell = (v) => { const s = v == null ? "" : String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
export function downloadCsv(name, header, rows) {
  const text = [header, ...rows].map((r) => r.map(csvCell).join(",")).join("\r\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type: "text/csv" }));
  a.download = name.replace(/[^\w.-]+/g, "-") + ".csv";
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}
export function reportCsv(r) {
  const cols = r.columns || [], p = r.period || {};
  const rows = (r.rows || []).map((x) => cols.map((c) => x[c.key] ?? ""));
  if ((r.rows || []).length) rows.push(cols.map((c, i) => i === 0 ? "Total" : (r.totals || {})[c.key] ?? ""));
  downloadCsv(r.title + " " + (p.as_of || (p.from + " to " + p.to)), cols.map((c) => c.label), rows);
}

// ---------------------------------------------------------------------------
// Owner portal: statement for any date range (print or CSV) and a year-end summary.
export async function mountOwnerReports(el) {
  ensureReportCss();
  el.innerHTML = `<p class="rq-sub">Loading…</p>`;
  const { data: acct, error } = await client.rpc("condo_my_account");
  if (error) { el.innerHTML = `<p class="rq-msg err">${esc(await errorText(error))}</p>`; return; }
  const units = acct.units || [], thisYear = new Date().getFullYear(), today = new Date().toISOString().slice(0, 10);
  const firstYear = Math.min(thisYear, ...units.flatMap((u) => u.accounts.flatMap((a) => a.entries.map((e) => Number(e.date.slice(0, 4))))));
  const years = []; for (let y = thisYear; y >= firstYear; y--) years.push(y);
  el.innerHTML = `<div class="rq">
    <div class="rq-card"><h2>Account statement</h2><p class="rq-sub">Every charge and payment on your association account for the dates you choose, with a running balance. Print it, save it as a PDF from the print window, or download it for a spreadsheet.</p>
      <div class="rq-form">
        ${units.length > 1 ? `<label>Unit<select id="rqUnit">${units.map((u) => `<option value="${esc(u.unit_number)}">Unit ${esc(u.unit_number)}</option>`).join("")}</select></label>` : ""}
        <label>From<input type="date" id="rqFrom" value="${thisYear}-01-01"></label><label>To<input type="date" id="rqTo" value="${today}"></label>
        <button class="rq-btn" type="button" id="rqPrint">Print statement</button><button class="rq-btn ghost" type="button" id="rqCsv">Download CSV</button></div></div>
    <div class="rq-card"><h2>Year-end summary</h2><p class="rq-sub">What was charged and what you paid in one calendar year, by item (dues, late fees and anything else), with the balance at the start and end of the year. Useful at tax time.</p>
      <div class="rq-form"><label>Year<select id="rqYear">${years.map((y) => `<option>${y}</option>`).join("")}</select></label>
        <button class="rq-btn" type="button" id="rqShow">Show</button><button class="rq-btn ghost" type="button" id="rqYPrint">Print</button><button class="rq-btn ghost" type="button" id="rqYCsv">Download CSV</button></div>
      <div class="rq-msg" id="rqMsg" role="status"></div><div class="rq-view" id="rqView"></div></div></div>`;
  const $ = (id) => el.querySelector("#" + id);
  const unit = () => units.find((u) => u.unit_number === ($("rqUnit") ? $("rqUnit").value : units[0] && units[0].unit_number));
  $("rqPrint").onclick = () => { const u = unit(); if (u) printStatement({ ...u, owner: acct.owner, pay_instructions: acct.pay_instructions }, $("rqFrom").value || null, $("rqTo").value || null); };
  $("rqCsv").onclick = () => {
    const u = unit(); if (!u) return;
    const from = $("rqFrom").value || "", to = $("rqTo").value || "", rows = [];
    u.accounts.forEach((a) => {
      let run = a.entries.filter((e) => from && e.date < from).reduce((t, e) => t + Number(e.amount), 0);
      if (from) rows.push([a.owner, from, "Balance forward", "", "", run.toFixed(2)]);
      a.entries.filter((e) => (!from || e.date >= from) && (!to || e.date <= to)).forEach((e) => {
        run += Number(e.amount);
        rows.push([a.owner, e.date, (e.description || e.type || "") + (e.check_number ? " #" + e.check_number : ""), e.amount > 0 ? Number(e.amount).toFixed(2) : "", e.amount < 0 ? (-e.amount).toFixed(2) : "", run.toFixed(2)]);
      });
    });
    downloadCsv(`Unit ${u.unit_number} statement ${from || "start"} to ${to || today}`, ["Account", "Date", "Description", "Charge", "Payment/credit", "Balance"], rows);
  };
  let rep = null;
  const load = async () => {
    $("rqMsg").textContent = "";
    const { data, error } = await client.rpc("owner_report_year", { p_year: Number($("rqYear").value) });
    if (error) { $("rqMsg").className = "rq-msg err"; $("rqMsg").textContent = await errorText(error); return null; }
    rep = data; $("rqView").innerHTML = reportHtml(rep); return rep;
  };
  $("rqShow").onclick = load;
  $("rqYear").onchange = () => { rep = null; $("rqView").innerHTML = ""; };
  $("rqYPrint").onclick = async () => { if (rep || await load()) printReport(rep); };
  $("rqYCsv").onclick = async () => { if (rep || await load()) reportCsv(rep); };
}

// ---------------------------------------------------------------------------
// Resident portal: rent paid by calendar year.
export async function mountTenantReports(el) {
  ensureReportCss();
  el.innerHTML = `<p class="rq-sub">Loading…</p>`;
  const { data, error } = await client.rpc("resident_rent_by_year");
  if (error) { el.innerHTML = `<p class="rq-msg err">${esc(await errorText(error))}</p>`; return; }
  el.innerHTML = `<div class="rq"><div class="rq-card"><h2>Rent paid by year</h2>
    <p class="rq-sub">The rent you paid in each calendar year, from your ledger. Print it or save it as a PDF from the print window when someone asks for proof of rent paid.</p>
    <div class="rq-form"><button class="rq-btn" type="button" id="rtPrint">Print</button><button class="rq-btn ghost" type="button" id="rtCsv">Download CSV</button></div>
    <div class="rq-view">${reportHtml(data)}</div></div></div>`;
  el.querySelector("#rtPrint").onclick = () => printReport(data);
  el.querySelector("#rtCsv").onclick = () => reportCsv(data);
}
