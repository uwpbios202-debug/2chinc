// Property Management Agreements, reviewed and signed online (Stephen, 11/11/2026).
// Used by the owner portal (#pma, mode "owner") and the staff page /staff/pma/ (mode "staff": office and the ROCA1 president).
// Everyone can suggest new wording for a section or comment while it is under review; the office accepts or declines; when settled,
// the office sets it Ready to sign; owner and president sign by typing their name. Then pma-pdf files the signed PDF in the owner's Documents.
import { client, esc, fmtDate } from "/assets/portal/portal.js";

const STATUS = { draft: "Draft (not sent yet)", review: "Under review: suggest changes", ready: "Ready to sign", signed: "Signed by both", void: "Void" };
const ROLE = { owner: "Owner", president: "President", office: "Office" };
const when = (t) => t ? new Date(t).toLocaleString("en-US", { timeZone: "America/Chicago", month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }) : "";
const CSS = `<style>
  .pma h3{margin:18px 0 4px}.pma .body{white-space:pre-wrap;line-height:1.5}.pma .sec{border-top:1px solid var(--line,#ddd);padding:10px 0}
  .pma .tag{display:inline-block;font-size:.78rem;padding:2px 8px;border-radius:99px;background:#eef3f0;color:#1f5c4a}
  .pma .tag.ready{background:#fbf0d9;color:#8a5a00}.pma .tag.signed{background:#e6f4ea;color:#1a7f37}
  .pma .sg{border-left:3px solid #c9c9c9;padding:6px 10px;margin:8px 0;font-size:.92rem}.pma .sg.open{border-color:#c98a00;background:#fffaf0}
  .pma .sg .prop{white-space:pre-wrap;background:#f4f4f4;padding:6px 8px;margin:4px 0;border-radius:4px}
  .pma textarea{width:100%;box-sizing:border-box;font:inherit;padding:6px 8px;min-height:110px;border:1px solid var(--line,#bbb);border-radius:6px;background:transparent;color:inherit}
  .pma input[type=text]{font:inherit;padding:6px 8px;border:1px solid var(--line,#bbb);border-radius:6px;min-width:240px;background:transparent;color:inherit}
  .pma .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:6px}.pma .meta{color:var(--muted,#666);font-size:.88rem}
  .pma .signbox{border:2px solid #111;border-radius:8px;padding:12px 14px;margin:14px 0}.pma .err{color:#b3261e}
</style>`;

export async function pmaList(mode) {
  const { data, error } = await client.rpc(mode === "staff" ? "pma_staff_list" : "pma_mine");
  if (error) throw error;
  return data || [];
}

export async function mountPma(el, mode) {
  el.innerHTML = `<p class="meta">Loading…</p>`;
  let list;
  try { list = await pmaList(mode); } catch (e) { el.innerHTML = `<p class="err">${esc(e.message)}</p>`; return; }
  if (!list.length) { el.innerHTML = `<p class="meta">No agreement to show.</p>`; return; }
  el.innerHTML = CSS;
  list.forEach((a) => el.appendChild(card(a, mode, () => mountPma(el, mode))));
}

function card(a, mode, reload) {
  const box = document.createElement("div");
  box.className = "panel card pma";
  const isStaff = a.role === "office" || a.role === "president";
  const canSuggest = a.status === "review" && a.role && !a.view_as;
  const open = a.suggestions.filter((s) => s.status === "open");
  const say = (t, bad) => { const m = box.querySelector("[data-say]"); m.textContent = t; m.className = bad ? "err" : "meta"; };
  const sigLine = (who, name, at) => at ? `<div><b>${esc(who)}:</b> /s/ ${esc(name)} <span class="meta">· signed ${esc(when(at))}</span></div>` : `<div><b>${esc(who)}:</b> <span class="meta">not signed yet</span></div>`;

  box.innerHTML = `<h2 style="margin-top:0">${esc(a.title)}</h2>
    <div class="row"><span class="tag ${a.status}">${esc(STATUS[a.status] || a.status)}</span><span class="meta">Version ${a.version} · ${esc(a.owner_name)} and ROCA1 (${esc(a.president_name)}, President), with 2nd Chance Housing Inc</span></div>
    ${a.view_as ? `<p class="meta"><b>Viewing as someone else:</b> you can read this, but suggestions and signatures must be made by the person themselves.</p>` : ""}
    ${a.status === "review" ? `<p class="meta">Read each section. To change one, press <b>Suggest a change</b> under it. Every suggestion is emailed to ${esc(a.owner_name)}, ${esc(a.president_name)} and the office; the office accepts or declines it. ${open.length ? `<b>${open.length} open.</b>` : ""}</p>` : ""}
    ${isStaff ? `<div class="row">${a.status === "draft" ? `<button class="btn primary" data-act="send">Send for review</button><span class="meta">Emails ${esc(a.owner_name)} and ${esc(a.president_name)}.</span>` : ""}
      ${a.status === "review" ? `<button class="btn primary" data-act="ready"${open.length ? " disabled" : ""}>Ready to sign</button><span class="meta">${open.length ? "Answer every open suggestion first." : "Locks the text and asks both to sign."}</span>` : ""}
      ${a.status === "ready" ? `<button class="btn" data-act="reopen">Reopen for changes</button><span class="meta">Clears any signature given.</span>` : ""}</div>` : ""}
    <div class="row"><span data-say class="meta" role="status"></span></div>
    <div data-secs></div>
    <div class="sec"><h3>Owner's address for statements and notices</h3><div class="body">Mailing address on file: ${esc(a.contact?.mail_to || "(none on file)")}\nPhone on file: ${esc(a.contact?.phone || "(none on file)")}</div>
      <p class="meta">From the owner record. ${mode === "owner" ? "To change it, use Update my info in this portal." : "Change it on the owner record."}</p></div>
    ${exhibit(a, mode)}
    <div data-sign></div>
    ${a.changes.length ? `<details class="sec"><summary>Change history (${a.changes.length})</summary>${a.changes.map((c) => `<div class="sg"><b>v${c.version}</b> · ${esc(secTitle(a, c.section_key))} · ${esc(when(c.created_at))}<div class="meta">${esc(c.note || "")}</div></div>`).join("")}</details>` : ""}`;

  const secs = box.querySelector("[data-secs]");
  a.sections.forEach((s) => {
    const d = document.createElement("div");
    d.className = "sec";
    const sgs = a.suggestions.filter((x) => x.section_key === s.key);
    d.innerHTML = `<h3>${esc(s.title)}</h3><div class="body">${esc(s.body)}</div>
      ${sgs.map((x) => sgHtml(x, isStaff && a.status === "review" && !a.view_as)).join("")}
      <div class="row">${canSuggest ? `<button class="btn small" data-sug>Suggest a change</button>` : ""}${isStaff && !a.view_as && (a.status === "draft" || a.status === "review") ? `<button class="btn small" data-edit>Edit (office)</button>` : ""}</div>
      <div data-form></div>`;
    const form = d.querySelector("[data-form]");
    d.querySelector("[data-sug]")?.addEventListener("click", () => {
      form.innerHTML = `<p class="meta">Change the wording below (or leave it as is and only write a comment or question).</p>
        <textarea data-prop>${esc(s.body)}</textarea>
        <label class="meta" style="display:block;margin-top:6px">Why, or your question<textarea data-com style="min-height:60px" maxlength="2000"></textarea></label>
        <div class="row"><button class="btn primary" data-go>Send suggestion to everyone</button><button class="btn" data-x>Cancel</button></div>`;
      form.querySelector("[data-x]").onclick = () => { form.innerHTML = ""; };
      form.querySelector("[data-go]").onclick = async (e) => {
        let prop = form.querySelector("[data-prop]").value;
        if (prop.trim() === s.body.trim()) prop = "";
        e.target.disabled = true;
        const { error } = await client.rpc("pma_suggest", { p_id: a.id, p_section: s.key, p_proposed: prop, p_comment: form.querySelector("[data-com]").value });
        e.target.disabled = false;
        if (error) { say(error.message, true); return; }
        flush(); reload();
      };
    });
    d.querySelector("[data-edit]")?.addEventListener("click", () => {
      form.innerHTML = `<textarea data-prop>${esc(s.body)}</textarea>
        <label class="meta" style="display:block;margin-top:6px">Note for everyone (optional)<input type="text" data-note maxlength="300" style="width:100%"></label>
        <div class="row"><button class="btn primary" data-go>Save change${a.status === "review" ? " and email everyone" : ""}</button><button class="btn" data-x>Cancel</button></div>`;
      form.querySelector("[data-x]").onclick = () => { form.innerHTML = ""; };
      form.querySelector("[data-go]").onclick = async (e) => {
        e.target.disabled = true;
        const { error } = await client.rpc("pma_staff_edit", { p_id: a.id, p_section: s.key, p_body: form.querySelector("[data-prop]").value, p_note: form.querySelector("[data-note]").value });
        e.target.disabled = false;
        if (error) { say(error.message, true); return; }
        flush(); reload();
      };
    });
    d.querySelectorAll("[data-sg]").forEach((sgEl) => wireSg(sgEl, a, say, reload));
    secs.appendChild(d);
  });

  // Signing
  const sb = box.querySelector("[data-sign]");
  if (a.status === "ready" || a.status === "signed") {
    const mineSigned = a.role === "owner" ? a.owner_signed_at : a.role === "president" ? a.president_signed_at : true;
    const myName = a.role === "owner" ? a.owner_name : a.president_name;
    sb.innerHTML = `<div class="signbox"><h3 style="margin-top:0">Signatures</h3>
      ${sigLine(`Owner of Unit ${a.unit_number}`, a.owner_signed_name || a.owner_name, a.owner_signed_at)}
      ${sigLine(`For ROCA1 (President) and for 2nd Chance Housing Inc`, a.president_signed_name || a.president_name, a.president_signed_at)}
      ${a.status === "ready" && !mineSigned && !a.view_as ? `<div style="margin-top:12px"><label class="row"><input type="checkbox" data-consent> I have read this agreement (version ${a.version}) and agree to sign it electronically. My typed name is my signature.</label>
        <div class="row"><input type="text" data-name placeholder="Type your full name: ${esc(myName)}" autocomplete="name"><button class="btn primary" data-signbtn>Sign</button></div></div>` : ""}
      ${a.status === "signed" ? `<div class="row" style="margin-top:10px">${a.pdf_path ? `<button class="btn primary" data-pdf>Open the signed PDF</button><span class="meta">Also under Documents${mode === "owner" ? " in this portal" : " in the owner's portal"}, to print at any time.</span>` : `<span class="meta">The signed PDF is being made.</span>${isStaff ? `<button class="btn" data-mkpdf>Make the PDF now</button>` : ""}`}</div>` : ""}</div>`;
    sb.querySelector("[data-signbtn]")?.addEventListener("click", async (e) => {
      e.target.disabled = true; say("Signing…");
      const { data, error } = await client.rpc("pma_sign", { p_id: a.id, p_name: sb.querySelector("[data-name]").value, p_consent: sb.querySelector("[data-consent]").checked });
      e.target.disabled = false;
      if (error) { say(error.message, true); return; }
      if (data === "signed") { say("Signed by both. Making the PDF…"); await makePdf(a.id); } else flush();
      reload();
    });
    sb.querySelector("[data-mkpdf]")?.addEventListener("click", async () => { say("Making the PDF…"); const r = await makePdf(a.id); if (r) say(r, true); else reload(); });
    sb.querySelector("[data-pdf]")?.addEventListener("click", async () => {
      const w = window.open("", "_blank");
      const { data, error } = await client.storage.from("owner-docs").createSignedUrl(a.pdf_path, 300);
      if (error || !data) { if (w) w.close(); say("We couldn't open the PDF. Try again.", true); return; }
      if (w) w.location = data.signedUrl; else location.href = data.signedUrl;
    });
  }

  box.querySelector("[data-act]") && box.querySelectorAll("[data-act]").forEach((b) => b.addEventListener("click", async () => {
    const act = b.dataset.act;
    const q = act === "send" ? `Email ${a.owner_name} and ${a.president_name} that the agreement is ready for review?` : act === "ready" ? "Lock the text and ask both to sign?" : "Reopen for changes? Any signature already given is cleared and everyone is emailed.";
    if (!confirm(q)) return;
    b.disabled = true;
    const { error } = act === "send" ? await client.rpc("pma_staff_send", { p_id: a.id }) : await client.rpc("pma_staff_status", { p_id: a.id, p_to: act === "ready" ? "ready" : "review" });
    b.disabled = false;
    if (error) { say(error.message, true); return; }
    flush(); reload();
  }));
  return box;
}

// Exhibit A: the unit's eviction expense budget (estimate), referred to by section 5a.
function exhibit(a, mode) {
  const e = a.eviction; if (!e) return "";
  const money = (n) => Number(n || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
  return `<div class="sec"><h3>Exhibit A: what an eviction costs (estimate)</h3>
    <p class="meta">The eviction expense budget for Unit ${esc(a.unit_number)} that section 5a refers to. Court and Sheriff fees change; rows "to be entered" depend on the case.
      ${mode === "owner" ? 'You can change your own copy under <a href="#eviction">Eviction costs</a>; this exhibit always shows it.' : "The owner can change their own copy on the owner portal (Eviction costs)."}</p>
    <div style="overflow-x:auto"><table style="width:100%;border-collapse:collapse;font-size:.92rem">
      <thead><tr><th style="text-align:left;border-bottom:1px solid #bbb;padding:5px">Expense</th><th style="text-align:left;border-bottom:1px solid #bbb;padding:5px">What it covers</th><th style="text-align:right;border-bottom:1px solid #bbb;padding:5px">Amount</th></tr></thead><tbody>
      ${e.items.map((r) => `<tr><td style="padding:5px;vertical-align:top;border-bottom:1px solid #eee"><b>${esc(r.expense)}</b></td><td style="padding:5px;vertical-align:top;border-bottom:1px solid #eee">${esc(r.covers)}${r.note ? `<div class="meta">${esc(r.note)}</div>` : ""}</td>
        <td style="padding:5px;text-align:right;white-space:nowrap;vertical-align:top;border-bottom:1px solid #eee">${Number(r.amount) ? money(r.amount) : "to be entered"}</td></tr>`).join("")}
      <tr><td colspan="2" style="padding:5px"><b>Known costs so far</b> (rows "to be entered" are not counted)</td><td style="padding:5px;text-align:right"><b>${money(e.total)}</b></td></tr></tbody></table></div></div>`;
}

function secTitle(a, key) { return (a.sections.find((s) => s.key === key) || {}).title || ""; }

function sgHtml(x, canResolve) {
  const label = x.status === "open" ? "open" : x.status;
  return `<div class="sg ${x.status === "open" ? "open" : ""}" data-sg="${x.id}" data-mine="${x.mine ? 1 : 0}" data-open="${x.status === "open" ? 1 : 0}">
    <b>${esc(x.by_name)}</b> <span class="meta">(${esc(ROLE[x.by_role] || x.by_role)}) · ${esc(when(x.created_at))} · ${esc(label)}</span>
    ${x.comment ? `<div style="white-space:pre-wrap">${esc(x.comment)}</div>` : ""}
    ${x.proposed ? `<div class="meta">Suggested wording:</div><div class="prop">${esc(x.proposed)}</div>` : ""}
    ${x.response ? `<div class="meta">Office reply: ${esc(x.response)}</div>` : ""}
    ${x.status === "open" && canResolve ? `<div class="row">${x.proposed ? `<button class="btn small primary" data-acc>Accept…</button>` : ""}<button class="btn small" data-dec>${x.proposed ? "Decline…" : "Reply…"}</button></div><div data-rform></div>` : ""}
    ${x.status === "open" && x.mine ? `<div class="row"><button class="btn small" data-wd>Withdraw</button></div>` : ""}</div>`;
}

function wireSg(el, a, say, reload) {
  const id = el.dataset.sg, x = a.suggestions.find((s) => s.id === id), rf = el.querySelector("[data-rform]");
  el.querySelector("[data-wd]")?.addEventListener("click", async () => {
    const { error } = await client.rpc("pma_withdraw", { p_suggestion: id });
    if (error) { say(error.message, true); return; } reload();
  });
  el.querySelector("[data-acc]")?.addEventListener("click", () => {
    rf.innerHTML = `<p class="meta">Accept this wording, or edit it first. The section is replaced and everyone is emailed.</p><textarea data-b>${esc(x.proposed || "")}</textarea>
      <input type="text" data-r placeholder="Reply (optional)" maxlength="2000" style="width:100%;margin-top:6px">
      <div class="row"><button class="btn primary" data-go>Accept and email everyone</button></div>`;
    rf.querySelector("[data-go]").onclick = async (e) => {
      e.target.disabled = true;
      const { error } = await client.rpc("pma_staff_resolve", { p_suggestion: id, p_action: "accept", p_body: rf.querySelector("[data-b]").value, p_reply: rf.querySelector("[data-r]").value });
      e.target.disabled = false;
      if (error) { say(error.message, true); return; } flush(); reload();
    };
  });
  el.querySelector("[data-dec]")?.addEventListener("click", () => {
    rf.innerHTML = `<textarea data-r placeholder="${x.proposed ? "Why it is declined (sent to everyone)" : "Your answer (sent to everyone)"}" style="min-height:60px" maxlength="2000"></textarea>
      <div class="row"><button class="btn primary" data-go>${x.proposed ? "Decline" : "Send answer"} and email everyone</button></div>`;
    rf.querySelector("[data-go]").onclick = async (e) => {
      e.target.disabled = true;
      const { error } = await client.rpc("pma_staff_resolve", { p_suggestion: id, p_action: x.proposed ? "decline" : "reply", p_body: null, p_reply: rf.querySelector("[data-r]").value });
      e.target.disabled = false;
      if (error) { say(error.message, true); return; } flush(); reload();
    };
  });
}

function flush() { client.functions.invoke("outbox-flush", { body: {} }).catch(() => {}); }

async function makePdf(id) {
  const { data, error } = await client.functions.invoke("pma-pdf", { body: { id } });
  if (error) { try { return (await error.context.json()).error; } catch { return "The PDF could not be made. Try again."; } }
  return data && data.ok ? null : "The PDF could not be made. Try again.";
}
