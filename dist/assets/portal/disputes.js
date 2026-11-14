// Charge disputes for tenants (resident portal) and owners (owner portal).
// Question a charge on your ledger; the office answers, denies with an explanation, or credits it. The original
// charge always stays on the ledger; a credit is a new line right after it.
//   mountDisputes(el, { side: "tenant" | "owner" })  — the card: question a charge + your questions and answers
//   questionCharge(el, { side, id } | { side, date, amount, memo }) — open the card with that charge chosen
//     (resident ledger rows have no id, so they match on date + amount (+ memo)).
// Database: supabase/migrations/20261106020000_household_disputes.sql.
import { client, esc, fmtDate, money, errorText } from "/assets/portal/portal.js";

const CSS = `
.cd{display:grid;gap:14px}.cd-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.cd h2{margin:0 0 6px;font-size:1.2rem}.cd-sub{color:#5b6573;font-size:.88rem;margin:0}
.cd-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin-top:10px}
.cd-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}.cd-form .wide{grid-column:1/-1}
.cd-form input,.cd-form select,.cd-form textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.cd-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:10px 20px;font-weight:700;cursor:pointer}.cd-btn:disabled{opacity:.5}
.cd-link{background:none;border:0;color:#2e7d1f;font-weight:600;cursor:pointer;padding:0;text-decoration:underline}
.cd-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.cd-pill.open{background:#fff3cd;color:#7a5200}.cd-pill.answered{background:#e3eefb;color:#1f4d8a}.cd-pill.denied,.cd-pill.withdrawn{background:#eee;color:#555}
.cd-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.cd-msg.err{color:#b3261e}.cd-msg.ok{color:#2e7d1f}
.cd-row{border-top:1px solid #eef1ec;padding:10px 0}
.cd-thread{margin:6px 0 0;padding:0;list-style:none;display:grid;gap:6px}
.cd-thread li{background:#f6f8f5;border-radius:8px;padding:6px 10px;font-size:.9rem}.cd-thread li.staff{background:#eef4fb}`;

const STATUS = { open: "waiting for the office", answered: "office answered", adjusted: "credited", denied: "charge stands", withdrawn: "withdrawn" };
let pendingMatch = null;

export function questionCharge(el, match) {
  pendingMatch = match;
  return mountDisputes(el, { side: match.side || "tenant" }).then(() => el.scrollIntoView({ behavior: "smooth", block: "start" }));
}

function findLine(lines, m) {
  if (!m) return null;
  if (m.id != null) return lines.find((x) => String(x.id) === String(m.id)) || null;
  const amt = Number(m.amount), same = lines.filter((x) => x.date === m.date && Math.abs(Number(x.amount) - amt) < 0.005);
  return (m.memo && same.find((x) => x.description === m.memo)) || same[0] || null;
}

export async function mountDisputes(el, opts = {}) {
  const side = opts.side === "owner" ? "owner" : "tenant";
  if (!document.getElementById("cd-css")) { const s = document.createElement("style"); s.id = "cd-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="cd-sub">Loading…</p>`;
  const { data, error } = await client.rpc("disputes_mine");
  if (error) { el.innerHTML = `<p class="cd-msg err">${esc(await errorText(error))}</p>`; return; }
  const lines = (side === "owner" ? data.owner_lines : data.tenant_lines) || [];
  const mine = (data.disputes || []).filter((d) => d.side === side);
  const openIds = new Set(mine.filter((d) => d.status === "open" || d.status === "answered").map((d) => String(side === "owner" ? d.condo_entry_id : d.lease_entry_id)));
  const pick = findLine(lines, pendingMatch && (pendingMatch.side || "tenant") === side ? pendingMatch : null); pendingMatch = null;
  const label = (x) => `${fmtDate(x.date)} · ${x.description || x.type || "Charge"} · ${money(Number(x.amount))}${lines.some((y) => y.unit !== x.unit) ? " · Unit " + x.unit : ""}`;
  el.innerHTML = `<div class="cd">
    <div class="cd-card"><h2>Question a charge</h2>
      <p class="cd-sub">If a charge on your ${side === "owner" ? "association account" : "rent ledger"} looks wrong, tell us why. The office will answer by email and here. If we agree, we credit your account; the original charge stays on the ledger with the credit right after it. Questioning a charge does not stop late fees or notices by itself, so if a payment is due, please pay what you don't dispute${data.office_phone ? " or call " + esc(data.office_phone) : ""}.</p>
      ${lines.length ? `<form class="cd-form" id="cdForm" novalidate>
        <label class="wide">Which charge?<select id="cdLine">${pick ? "" : `<option value="">Choose a charge…</option>`}${lines.map((x) =>
          `<option value="${esc(x.id)}" ${pick && pick.id === x.id ? "selected" : ""} ${openIds.has(String(x.id)) ? "disabled" : ""}>${esc(label(x))}${openIds.has(String(x.id)) ? " (already questioned)" : ""}</option>`).join("")}</select></label>
        <label>Amount you question<input id="cdAmt" type="number" min="0.01" step="0.01" inputmode="decimal" placeholder="The whole charge"></label>
        <label class="wide">What's wrong with it?<textarea id="cdWhy" rows="3" maxlength="2000" placeholder="For example: I was charged twice for October."></textarea></label>
        <div class="wide"><button class="cd-btn" type="submit" id="cdSend">Send to the office</button><div class="cd-msg" id="cdMsg" role="status"></div></div>
      </form>` : `<p class="cd-sub" style="margin-top:8px">No charges in the last two years to question.</p>`}
    </div>
    <div class="cd-card"><h2>Your questions</h2>
      ${mine.length ? mine.map((d) => `<div class="cd-row">
        <div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap"><b>${fmtDate(d.entry_date)} · ${esc(d.entry_description || "Charge")} · ${money(Number(d.entry_amount))}</b><span class="cd-pill ${esc(d.status)}">${esc(STATUS[d.status] || d.status)}</span></div>
        <div class="cd-sub">${d.unit_number ? "Unit " + esc(d.unit_number) + " · " : ""}questioned ${money(Number(d.amount_disputed))} on ${fmtDate(d.created_at)}${d.adjustment_amount ? ` · credited ${money(Number(d.adjustment_amount))}` : ""}</div>
        <ul class="cd-thread">${(d.thread || []).map((t) => `<li class="${t.by === "staff" ? "staff" : ""}"><b>${t.by === "staff" ? "Office" : "You"}</b> <span class="cd-sub">${fmtDate(t.at)}</span><br>${esc(t.text)}</li>`).join("")}</ul>
        ${d.status === "open" || d.status === "answered" ? `<div class="cd-form" style="grid-template-columns:1fr auto auto;align-items:end">
          <label>Reply<input data-cdreplytext="${esc(d.id)}" maxlength="2000"></label>
          <button class="cd-link" type="button" data-cdreply="${esc(d.id)}">Send reply</button>
          <button class="cd-link" type="button" data-cdwithdraw="${esc(d.id)}">Withdraw</button></div>` : ""}
      </div>`).join("") : `<p class="cd-sub">You haven't questioned any charges.</p>`}
    </div></div>`;

  const q = (id) => el.querySelector("#" + id);
  const say = (t, bad) => { q("cdMsg").className = "cd-msg " + (bad ? "err" : "ok"); q("cdMsg").textContent = t; };
  const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
  if (q("cdLine")) {
    const setMax = () => { const x = lines.find((y) => String(y.id) === q("cdLine").value); q("cdAmt").max = x ? x.amount : ""; q("cdAmt").placeholder = x ? money(Number(x.amount)) + " (the whole charge)" : "The whole charge"; };
    q("cdLine").onchange = setMax; setMax();
    if (pick) q("cdWhy").focus();
    q("cdForm").onsubmit = async (e) => {
      e.preventDefault();
      if (!q("cdLine").value) return say("Choose the charge.", true);
      q("cdSend").disabled = true; say("Sending…");
      const amt = q("cdAmt").value.trim();
      const { error: err } = await client.rpc("dispute_create", { p_side: side, p_entry: Number(q("cdLine").value), p_amount: amt ? Number(amt) : null, p_reason: q("cdWhy").value.trim() });
      if (err) { q("cdSend").disabled = false; return say(await errorText(err), true); }
      flush();
      await mountDisputes(el, opts);
      const m = el.querySelector("#cdMsg"); if (m) { m.className = "cd-msg ok"; m.textContent = "Sent. The office will answer by email and here."; }
    };
  }
  el.querySelectorAll("[data-cdreply]").forEach((b) => b.onclick = async () => {
    const t = el.querySelector(`[data-cdreplytext="${b.dataset.cdreply}"]`).value.trim();
    if (!t) return alert("Write your reply first.");
    const { error: err } = await client.rpc("dispute_reply", { p_id: b.dataset.cdreply, p_text: t });
    if (err) return alert(await errorText(err));
    flush(); mountDisputes(el, opts);
  });
  el.querySelectorAll("[data-cdwithdraw]").forEach((b) => b.onclick = async () => {
    if (!confirm("Withdraw this question? The charge stays as it is.")) return;
    const { error: err } = await client.rpc("dispute_withdraw", { p_id: b.dataset.cdwithdraw });
    if (err) return alert(await errorText(err));
    mountDisputes(el, opts);
  });
}
