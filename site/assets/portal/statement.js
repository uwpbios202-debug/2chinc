// Association account statement, shared by the owner page and the staff
// Association page. Prints from a hidden #printArea (portal.css hides the rest
// of the page when body.printing is set).
import { esc, fmtDate, money, balCell, CREDIT_NOTE } from "/assets/portal/portal.js";

// unit: { unit_number, address, pin, owner, accounts: [{ owner, owner_label, entries: [...] }] }
export function statementHtml(unit, from, to) {
  const inRange = (d) => (!from || d >= from) && (!to || d <= to);
  let opening = 0, closing = 0;
  const sections = unit.accounts.map((a) => {
    const before = a.entries.filter((e) => from && e.date < from).reduce((t, e) => t + Number(e.amount), 0);
    const rows = a.entries.filter((e) => inRange(e.date));
    const end = a.entries.filter((e) => !to || e.date <= to).reduce((t, e) => t + Number(e.amount), 0);
    opening += before; closing += end;
    if (!rows.length && !before && !end) return "";
    let run = before;
    return `${unit.accounts.length > 1 ? `<h3 style="margin:14px 0 4px">Account: ${esc(a.owner)}${a.owner_label !== a.owner ? ` (billed as ${esc(a.owner_label)})` : ""}</h3>` : ""}
      <table class="st"><thead><tr><th>Date</th><th>Description</th><th class="n">Charges</th><th class="n">Payments &amp; credits</th><th class="n">Balance</th></tr></thead><tbody>
      ${from ? `<tr><td>${fmtDate(from)}</td><td><i>Balance forward</i></td><td></td><td></td><td class="n">${balCell(before)}</td></tr>` : ""}
      ${rows.map((e) => { run += Number(e.amount); return `<tr><td>${fmtDate(e.date)}</td><td>${esc(e.description || e.type)}${e.check_number ? ` #${esc(e.check_number)}` : ""}${e.note ? `<div class="sm">${esc(e.note)}</div>` : ""}</td>
        <td class="n">${e.amount > 0 ? money(e.amount) : ""}</td><td class="n">${e.amount < 0 ? money(-e.amount) : ""}</td><td class="n">${balCell(run)}</td></tr>`; }).join("")}
      </tbody></table>`;
  }).join("");
  return `<div class="statement">
    <div style="display:flex;justify-content:space-between;gap:20px;align-items:flex-start">
      <div><b>Royal Orleans Condominium – Addition One</b><br>managed by 2nd Chance Housing Inc.<br>6626 N. Bourbon St., Milwaukee, WI 53224</div>
      <div style="text-align:right"><b style="font-size:1.3em">Account statement</b><br>${from ? fmtDate(from) : "All history"} – ${fmtDate(to || new Date().toISOString().slice(0, 10))}<br>Printed ${fmtDate(new Date().toISOString())}</div>
    </div>
    <p style="margin:18px 0 6px"><b>${esc(unit.owner)}</b><br>Unit ${esc(unit.unit_number)} · ${esc(unit.address || "")}${unit.pin ? `<br>Account # ${esc(unit.pin)}` : ""}</p>
    <div class="st-sum"><span>Opening balance <b>${balCell(opening)}</b></span><span>Amount due <b>${money(Math.max(closing, 0))}</b></span>${closing < -0.004 ? `<span>Credit <b>${money(-closing)}</b> <i style="font-weight:400">${CREDIT_NOTE}</i></span>` : ""}</div>
    ${sections}
    ${unit.pay_instructions ? `<p style="margin-top:16px">${esc(unit.pay_instructions)}</p>` : ""}
  </div>`;
}

export function printStatement(unit, from, to) {
  let area = document.getElementById("printArea");
  if (!area) { area = document.createElement("div"); area.id = "printArea"; document.body.appendChild(area); }
  area.innerHTML = statementHtml(unit, from, to);
  document.body.classList.add("printing");
  const done = () => { document.body.classList.remove("printing"); window.removeEventListener("afterprint", done); };
  window.addEventListener("afterprint", done);
  window.print();
}

export const STATEMENT_CSS = `
  #printArea { display: none; }
  .statement { font-size: 13px; color: #000; background: #fff; }
  .statement table.st { width: 100%; border-collapse: collapse; margin-top: 4px; }
  .statement table.st th, .statement table.st td { border-bottom: 1px solid #ccc; padding: 4px 6px; text-align: left; vertical-align: top; }
  .statement .n { text-align: right; white-space: nowrap; }
  .statement .sm { font-size: 11px; color: #555; }
  .statement .st-sum { display: flex; gap: 30px; padding: 8px 0; border-top: 2px solid #000; border-bottom: 2px solid #000; margin: 8px 0; }
  @media print {
    body.printing > *:not(#printArea) { display: none !important; }
    body.printing #printArea { display: block; }
    body.printing { background: #fff; }
  }`;
