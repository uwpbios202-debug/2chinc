// ROCA1 board business for owners (owner portal #board).
// Directors vote for their seat and members vote per unit on open resolutions; a unit that isn't in good standing
// (any balance, or a recorded lien — Rules & Regulations 2024 §11) is shown with the reason it can't vote.
// Also: decided resolutions, the special assessments and liens on the owner's units, and the current budget.
// Database: supabase/migrations/20261106060000_roca_governance_core.sql, 20261106070000_roca_budget_assessments_liens.sql.
import { client, esc, fmtDate, money, errorText } from "/assets/portal/portal.js";

const CSS = `
.rb{display:grid;gap:14px}.rb-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.rb h2{margin:0 0 6px;font-size:1.2rem}.rb h3{margin:10px 0 4px;font-size:1rem}.rb-sub{color:#5b6573;font-size:.88rem;margin:0}
.rb-body{white-space:pre-wrap;background:#f6f8f5;border-radius:8px;padding:8px 10px;margin:6px 0;font-size:.95rem}
.rb-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.rb-pill.no{background:#eee;color:#555}.rb-pill.warn{background:#fff3cd;color:#7a5200}.rb-pill.bad{background:#fde2e1;color:#8a1c1c}
.rb-vote{display:flex;gap:8px;flex-wrap:wrap;align-items:center;border-top:1px solid #eef1ec;padding:8px 0}
.rb-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:8px 16px;font-weight:700;cursor:pointer}.rb-btn.ghost{background:#fff;color:#2e7d1f;border:1px solid #2e7d1f}
.rb-btn:disabled{opacity:.5}.rb-msg{min-height:1.2em;font-size:.9rem}.rb-msg.err{color:#b3261e}.rb-msg.ok{color:#2e7d1f}
.rb table{width:100%;border-collapse:collapse;font-size:.9rem}.rb td,.rb th{padding:4px 6px;border-top:1px solid #eef1ec;text-align:left}.rb .n{text-align:right;white-space:nowrap}`;

const KIND = { budget: "Budget", special_assessment: "Special assessment", violation_decision: "Violation decision", fine_waiver: "Fine waiver", lien_filing: "Liens",
  lien_satisfaction: "Lien satisfaction", foreclosure: "Foreclosure", rule: "Rules / by-laws", other: "Other" };
const LIEN = { approved: "approved, to be recorded", recorded: "recorded", satisfaction_approved: "paid — satisfaction being recorded", satisfied: "satisfied", released: "released", foreclosure: "foreclosure" };
const tallyText = (t) => t ? `${t.yes} yes · ${t.no} no${t.abstain ? " · " + t.abstain + " abstain" : ""} — ${esc(t.rule)}` : "";

export async function mountBoard(el) {
  if (!document.getElementById("rb-css")) { const s = document.createElement("style"); s.id = "rb-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="rb-sub">Loading…</p>`;
  const [a, b] = await Promise.all([client.rpc("roca_resolutions_mine"), client.rpc("roca_my_assessments_liens")]);
  if (a.error || b.error) { el.innerHTML = `<p class="rb-msg err">${esc(await errorText(a.error || b.error))}</p>`; return; }
  const R = a.data, M = b.data;
  const open = R.open || [], decided = R.decided || [], bud = M.budget;
  el.innerHTML = `<div class="rb">
    <div class="rb-card"><h2>Open for your vote</h2>
      ${open.length ? open.map((r) => `<div data-res="${esc(r.id)}" style="padding:8px 0;border-top:1px solid #eef1ec">
        <b>${esc(r.number || "")} · ${esc(r.title)}</b> <span class="rb-pill warn">${esc(KIND[r.kind] || r.kind)}</span>
        <div class="rb-sub">Voting closes ${fmtDate(r.closes_on)} · so far: ${tallyText(r.tally)}</div>
        ${r.body ? `<div class="rb-body">${esc(r.body)}</div>` : ""}
        ${(r.my_votes || []).map((v) => `<div class="rb-vote"><b style="min-width:110px">${esc(v.label)}</b>
          ${v.eligible ? `${v.vote ? `<span class="rb-pill">you voted ${esc(v.vote)}</span><span class="rb-sub">You can change your vote until voting closes.</span>` : ""}
            <input type="text" data-vnote="${esc(v.voter_key)}" maxlength="500" placeholder="Comment (optional)" aria-label="Comment on your vote" style="flex:1;min-width:160px;padding:6px 8px;border:1px solid #cfd6cc;border-radius:8px;font:inherit">
            <button class="rb-btn" type="button" data-v="yes" data-k="${esc(v.voter_key)}">Yes</button><button class="rb-btn ghost" type="button" data-v="no" data-k="${esc(v.voter_key)}">No</button>
            <button class="rb-btn ghost" type="button" data-v="abstain" data-k="${esc(v.voter_key)}">Abstain</button>${r.kind === "violation_decision" ? `<button class="rb-btn ghost" type="button" data-v="recused" data-k="${esc(v.voter_key)}">Recuse</button>` : ""}`
          : v.vote ? `<span class="rb-pill">your ${esc(v.vote)} vote is counted</span><span class="rb-sub">You voted while in good standing, so it stands.</span>`
          : `<span class="rb-pill no">can't vote: ${esc(v.reason || "not in good standing")}</span><span class="rb-sub">A unit votes with a $0.00 balance and no recorded lien (Rules & Regulations §11).</span>`}</div>`).join("")}
        <div class="rb-msg" data-msg></div></div>`).join("") : `<p class="rb-sub">Nothing is open for a vote.</p>`}</div>
    <div class="rb-card"><h2>Special assessments on your units</h2>
      ${(M.assessments || []).length ? `<table><thead><tr><th>Unit</th><th>Assessment</th><th>Due</th><th class="n">Amount</th><th></th></tr></thead><tbody>${M.assessments.map((x) => `<tr><td>${esc(x.unit)}</td>
        <td>${esc(x.number || "")} ${esc(x.title)}${x.installments > 1 ? ` (${x.installment} of ${x.installments})` : ""}<div class="rb-sub">${esc(x.reason)}</div></td><td>${fmtDate(x.due_date)}</td><td class="n">${money(x.amount)}</td>
        <td>${x.posted ? `<span class="rb-pill">on your account</span>` : `<span class="rb-pill warn">upcoming</span>`}</td></tr>`).join("")}</tbody></table>` : `<p class="rb-sub">None.</p>`}</div>
    <div class="rb-card"><h2>Liens on your units</h2>
      ${(M.liens || []).length ? `<table><thead><tr><th>Unit</th><th>Status</th><th>Document</th><th>Recorded</th><th class="n">Amount</th></tr></thead><tbody>${M.liens.map((l) => `<tr><td>${esc(l.unit)}</td>
        <td><span class="rb-pill ${["recorded", "foreclosure"].includes(l.status) ? "bad" : l.status === "satisfied" ? "no" : "warn"}">${esc(LIEN[l.status] || l.status)}</span></td>
        <td>${esc(l.rod_document || "")}${l.satisfaction_document ? ` · satisfaction ${esc(l.satisfaction_document)}` : ""}</td><td>${l.recorded_on ? fmtDate(l.recorded_on) : ""}${l.satisfied_on ? " · satisfied " + fmtDate(l.satisfied_on) : ""}</td>
        <td class="n">${l.amount_claimed != null ? money(l.amount_claimed) : ""}</td></tr>`).join("")}</tbody></table>
        <p class="rb-sub">A recorded lien is satisfied of record once the balance is paid in full.</p>` : `<p class="rb-sub">None.</p>`}</div>
    ${bud ? `<div class="rb-card"><h2>Budget, fiscal year ${esc(bud.fiscal_year)}</h2>
      <p class="rb-sub">${bud.status === "adopted" ? "Adopted by the Board." : "The budget on file."} Dues: <b>${money(bud.monthly_dues)}</b> per unit per month. Common expenses ${money(bud.totals.expenditures)}, income ${money(bud.totals.income)}${Number(bud.totals.shortfall) > 0 ? `, shortfall ${money(bud.totals.shortfall)} after carry-forward` : ""}.</p>
      <details><summary class="rb-sub">Expense lines</summary><table><tbody>${(bud.lines || []).filter((l) => Number(l.annual)).map((l) => `<tr><td>${esc(l.code)}</td><td>${esc(l.name)}</td><td class="n">${money(l.annual)}</td></tr>`).join("")}</tbody></table></details></div>` : ""}
    <div class="rb-card"><h2>Decided</h2>
      ${decided.length ? decided.map((r) => `<details style="border-top:1px solid #eef1ec;padding:6px 0"><summary><b>${esc(r.number || "")}</b> ${esc(r.title)} <span class="rb-pill ${r.status === "adopted" ? "" : "no"}">${esc(r.status)}</span> <span class="rb-sub">${fmtDate(r.decided_at)}</span></summary>
        ${r.body ? `<div class="rb-body">${esc(r.body)}</div>` : ""}${r.tally ? `<div class="rb-sub">${tallyText(r.tally)}</div>` : ""}</details>`).join("") : `<p class="rb-sub">Nothing yet.</p>`}</div></div>`;
  el.querySelectorAll("[data-res]").forEach((box) => box.querySelectorAll("[data-v]").forEach((btn) => btn.onclick = async () => {
    const msg = box.querySelector("[data-msg]");
    if (!confirm(`Cast your ${btn.closest(".rb-vote").querySelector("b").textContent} vote: ${btn.dataset.v.toUpperCase()}?`)) return;
    box.querySelectorAll("button").forEach((x) => { x.disabled = true; });
    const { error } = await client.rpc("roca_vote_mine", { p_id: box.dataset.res, p_voter: btn.dataset.k, p_vote: btn.dataset.v, p_note: (box.querySelector(`[data-vnote="${btn.dataset.k}"]`) || {}).value || null });
    if (error) { msg.className = "rb-msg err"; msg.textContent = await errorText(error); box.querySelectorAll("button").forEach((x) => { x.disabled = false; }); return; }
    mountBoard(el);
  }));
}
