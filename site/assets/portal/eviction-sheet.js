// Eviction costs for owners of the units in setting `eviction_sheet_owner_units` (Units 15, 16, 17). Since 11/11/2026 each owner edits their OWN copy per unit
// (starts from the office template; Stephen "option A"); sheets the office ties to a lease stay read-only.
// Print opens the sheet alone in a new window; Email sends it (as a table in the email body) to any one address.
import { client, esc } from "/assets/portal/portal.js";

const money = (n) => Number(n || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });

export async function evictionAllowed() {
  const { data, error } = await client.rpc("eviction_sheets_mine");
  return !error && data?.allowed ? data : null;
}

export function sheetTable(s) {
  const total = s.items.reduce((a, r) => a + (Number(r.amount) || 0), 0);
  return `<table class="evt"><thead><tr><th>Expense</th><th>What it covers</th><th>Cost status</th><th style="text-align:right">Amount</th></tr></thead><tbody>
    ${s.items.map((r) => `<tr><td><b>${esc(r.expense)}</b></td><td>${esc(r.covers)}${r.note ? `<div class="evn">${esc(r.note)}</div>` : ""}</td><td>${esc(r.status)}</td>
      <td style="text-align:right;white-space:nowrap">${Number(r.amount) ? money(r.amount) : "to be entered"}</td></tr>`).join("")}
    <tr><td colspan="3"><b>Known costs so far</b> (rows "to be entered" are not counted)</td><td style="text-align:right"><b>${money(total)}</b></td></tr></tbody></table>
    ${s.note ? `<p class="evn">${esc(s.note)}</p>` : ""}`;
}

export const SHEET_CSS = `table.evt{width:100%;border-collapse:collapse;font-size:.92rem}table.evt th,table.evt td{border:1px solid #bbb;padding:6px;vertical-align:top;text-align:left}
  table.evt th{font-size:.75rem;text-transform:uppercase}.evn{font-size:.82rem;color:#555;margin-top:3px}`;

export function printSheet(title, html) {
  const w = window.open("", "_blank");
  if (!w) { alert("Allow pop-ups for this site to print."); return; }
  w.document.write(`<!DOCTYPE html><html><head><meta charset="utf-8"><title>${esc(title)}</title><style>@page{size:letter;margin:.6in}
    body{font:10pt/1.35 Arial,Helvetica,sans-serif;color:#111}h1{font-size:15pt;margin:0 0 4px}${SHEET_CSS}tr{page-break-inside:avoid}</style></head>
    <body><h1>${esc(title)}</h1><p class="evn">2nd Chance Housing, for ROCA1 · printed ${new Date().toLocaleDateString("en-US")}</p>${html}
    <p class="evn">A budgeting tool, not legal advice.</p></body></html>`);
  w.document.close(); w.focus(); setTimeout(() => w.print(), 300);
}

// The email form: one address and an optional message.
export function emailForm(sheetId, onSent) {
  const box = document.createElement("div");
  box.className = "evmail";
  box.innerHTML = `<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:flex-end;margin-top:10px">
      <label style="display:grid;gap:3px;font-size:.85rem;flex:1;min-width:220px">Email to<input type="email" data-to maxlength="120" placeholder="name@example.com" style="font:inherit;padding:6px 8px"></label>
      <label style="display:grid;gap:3px;font-size:.85rem;flex:2;min-width:240px">Message (optional)<input data-msg maxlength="1500" style="font:inherit;padding:6px 8px"></label>
      <button class="btn primary" type="button" data-send>Send email</button></div><div class="sub" data-say role="status" style="margin-top:6px"></div>`;
  box.querySelector("[data-send]").addEventListener("click", async (e) => {
    const say = box.querySelector("[data-say]"), to = box.querySelector("[data-to]").value.trim();
    if (!to) { say.textContent = "Enter an email address."; return; }
    e.target.disabled = true; say.textContent = "Sending…";
    const { error } = await client.rpc("eviction_sheet_email", { p_id: sheetId, p_to: to, p_message: box.querySelector("[data-msg]").value });
    e.target.disabled = false;
    if (error) { say.textContent = error.message; return; }
    await client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
    say.textContent = `Sent to ${to}.`; box.querySelector("[data-to]").value = ""; box.querySelector("[data-msg]").value = "";
    onSent && onSent(to);
  });
  return box;
}

const EDIT_CSS = `table.evt input,table.evt textarea{font:inherit;width:100%;box-sizing:border-box;padding:4px 6px;border:1px solid #bbb;border-radius:5px;background:transparent;color:inherit}
  table.evt textarea{min-height:38px;resize:vertical;font-size:.85rem}table.evt .amt{width:96px;text-align:right}table.evt .rm{padding:2px 8px}`;

// Editable table for the owner's own copy.
function editTable(rows) {
  return `<table class="evt"><thead><tr><th>Expense</th><th>What it covers / your notes</th><th>Cost status</th><th style="text-align:right">Amount</th><th></th></tr></thead><tbody>
    ${rows.map((r, i) => `<tr data-i="${i}"><td><input data-f="expense" maxlength="200" value="${esc(r.expense)}"></td>
      <td><input data-f="covers" maxlength="500" value="${esc(r.covers)}"><textarea data-f="note" maxlength="2000" placeholder="Notes">${esc(r.note)}</textarea></td>
      <td><input data-f="status" maxlength="60" value="${esc(r.status)}"></td>
      <td style="text-align:right;white-space:nowrap">$<input class="amt" type="number" step="0.01" min="0" data-f="amount" value="${Number(r.amount) || 0}"></td>
      <td><button class="btn rm" type="button" data-rm title="Remove row">✕</button></td></tr>`).join("")}
    <tr><td colspan="3"><b>Known costs so far</b> (rows at $0 are not counted)</td><td style="text-align:right"><b data-total>${money(rows.reduce((a, r) => a + (Number(r.amount) || 0), 0))}</b></td><td></td></tr></tbody></table>`;
}

function editableCard(s, el) {
  const card = document.createElement("div");
  card.className = "panel evcard";
  const rows = s.items.map((r) => ({ ...r }));
  let note = s.note || "", dirty = false;
  const when = s.updated_at ? new Date(s.updated_at).toLocaleString("en-US", { timeZone: "America/Chicago", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";
  card.innerHTML = `<h3 style="margin-top:0">${esc(s.title)}</h3>
    <p class="sub">Your own copy for Unit ${esc(s.unit)}. Type your amounts and notes, then press Save. Your changes never change the office budget or anyone else's copy; the office can see this sheet.</p>
    <div style="overflow-x:auto" data-tbl></div>
    <label style="display:grid;gap:3px;font-size:.85rem;margin-top:10px">Notes for the whole sheet<textarea data-note maxlength="2000" style="font:inherit;padding:6px 8px;min-height:54px"></textarea></label>
    <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:10px;align-items:center">
      <button class="btn primary" type="button" data-save>Save</button><button class="btn" type="button" data-add>Add a row</button>
      <button class="btn" type="button" data-print>Print</button><button class="btn" type="button" data-reset>Start over from the office budget</button>
      <span class="sub" data-say role="status">${when ? "Last saved " + esc(when) : ""}</span></div>`;
  const tbl = card.querySelector("[data-tbl]"), say = card.querySelector("[data-say]"), noteEl = card.querySelector("[data-note]");
  noteEl.value = note;
  const draw = () => { tbl.innerHTML = editTable(rows); };
  const mark = () => { dirty = true; say.textContent = "Not saved yet."; };
  draw();
  tbl.addEventListener("input", (e) => {
    const tr = e.target.closest("tr[data-i]"); if (!tr || !e.target.dataset.f) return;
    const r = rows[+tr.dataset.i], f = e.target.dataset.f;
    r[f] = f === "amount" ? (parseFloat(e.target.value) || 0) : e.target.value;
    if (f === "amount") tbl.querySelector("[data-total]").textContent = money(rows.reduce((a, x) => a + (Number(x.amount) || 0), 0));
    mark();
  });
  tbl.addEventListener("click", (e) => {
    if (!("rm" in e.target.dataset)) return;
    const tr = e.target.closest("tr[data-i]"); rows.splice(+tr.dataset.i, 1); draw(); mark();
  });
  noteEl.addEventListener("input", () => { note = noteEl.value; mark(); });
  card.querySelector("[data-add]").addEventListener("click", () => { rows.push({ expense: "New expense", covers: "", status: "Variable", kind: "var", amount: 0, note: "" }); draw(); mark(); });
  card.querySelector("[data-save]").addEventListener("click", async (e) => {
    e.target.disabled = true; say.textContent = "Saving…";
    const { error } = await client.rpc("eviction_owner_sheet_save", { p_id: s.id, p_note: note, p_items: rows });
    e.target.disabled = false;
    if (error) { say.textContent = error.message; return; }
    dirty = false; say.textContent = "Saved.";
  });
  card.querySelector("[data-reset]").addEventListener("click", async () => {
    if (!confirm("Replace your Unit " + s.unit + " copy with the office budget? Your amounts and notes on this sheet will be lost.")) return;
    const { error } = await client.rpc("eviction_owner_sheet_reset", { p_id: s.id });
    if (error) { say.textContent = error.message; return; }
    mountEvictionSheets(el);
  });
  card.querySelector("[data-print]").addEventListener("click", () => printSheet(s.title, sheetTable({ items: rows, note })));
  const mf = emailForm(s.id);
  mf.querySelector("[data-send]").addEventListener("click", (e) => { if (dirty) { e.stopImmediatePropagation(); say.textContent = "Save first, then email."; } }, true);
  card.appendChild(mf);
  return card;
}

export async function mountEvictionSheets(el) {
  el.innerHTML = `<p class="sub">Loading…</p>`;
  const data = await evictionAllowed();
  if (!data) { el.innerHTML = `<p class="sub">Nothing to show.</p>`; return; }
  el.innerHTML = `<style>${SHEET_CSS}${EDIT_CSS}.evcard{margin-bottom:18px}</style>
    <p class="sub">What an eviction costs in Milwaukee County, from the first notice to getting the unit ready again. Edit your own copy, print it, or email it to yourself or anyone you choose.</p>`;
  data.sheets.forEach((s) => {
    if (s.editable) { el.appendChild(editableCard(s, el)); return; }
    const card = document.createElement("div");
    card.className = "panel evcard";
    card.innerHTML = `<h3 style="margin-top:0">${esc(s.title)}${s.unit ? ` <span class="sub">· Unit ${esc(s.unit)}</span>` : ""}</h3>
      <p class="sub">Prepared by the office (read-only).</p>
      <div style="overflow-x:auto">${sheetTable(s)}</div>
      <div style="margin-top:10px"><button class="btn" type="button" data-print>Print</button></div>`;
    card.querySelector("[data-print]").addEventListener("click", () => printSheet(s.title, sheetTable(s)));
    card.appendChild(emailForm(s.id));
    el.appendChild(card);
  });
}
