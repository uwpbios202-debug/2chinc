// Top of every Parking tab (resident, owner, Unit 6 parking-and-keys page), Stephen 11/8/2026:
//   1. "Your stall" card: today's stall, registered or not (deadline), parking hanger, parking allowed or revoked, rules signed or not, snow now.
//   2. The parking rules and the fines. Not signed yet: click to initial every rule and every fine, then record yourself reading the
//      statement out loud, then Submit (an email copy goes to them). Signed: "View my signed copy" shows the initials, the date and the recording.
// Database: parking_status_mine() (20261118420000_parking_status_hangers.sql), parking_terms_mine() / parking_ack_submit()
// (20261118430000_parking_rules_signing.sql). Full agreement: https://2ndchinc.org/documents/parking/
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

const CSS = `.pst{display:grid;gap:12px;margin-bottom:14px}
.pst .card{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:14px 16px;display:grid;gap:6px}
.pst .card.bad{border:2px solid #b3261e}.pst .card.good{border-left:6px solid #2e7d1f}.pst .card.warn{border-left:6px solid #b3261e}
.pst .big{font-size:1.25rem;font-weight:700}.pst .ok{color:#2e7d1f;font-weight:700}.pst .no{color:#b3261e;font-weight:700}
.pst .snow{background:#1b4b8a;color:#fff;border-radius:12px;padding:12px 16px;font-weight:600}
.pst .box{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:14px 16px;display:grid;gap:10px}
.pst .box h3{margin:0;font-size:1.1rem}.pst summary{cursor:pointer}
.pst .terms{display:grid;border-top:1px solid var(--line)}
.pst .term{display:grid;grid-template-columns:28px 1fr auto;gap:10px;align-items:center;padding:8px 0;border-bottom:1px solid var(--line)}
.pst .term .n{color:var(--muted);text-align:right}.pst .term .amt{font-weight:700;white-space:nowrap}
.pst .term.fine{grid-template-columns:1fr auto auto}
.pst .ini{min-width:74px;border:2px dashed #b3261e;background:transparent;color:#b3261e;border-radius:8px;padding:6px 10px;font-weight:700;cursor:pointer;font:inherit;text-align:center}
.pst .ini.done{border:2px solid #2e7d1f;color:#2e7d1f;background:rgba(46,125,31,.08);font-family:"Segoe Script","Brush Script MT",cursive;font-size:1.1rem;cursor:default}
.pst .step{border-left:4px solid #2e7d1f;padding:4px 12px}.pst .script{font-size:1.1rem;font-weight:600;background:rgba(46,125,31,.07);border-radius:8px;padding:10px 14px}
.pst .rec{border-radius:999px;padding:9px 16px;font-weight:700;cursor:pointer;border:1px solid #b3261e;background:#b3261e;color:#fff;font:inherit}
.pst .rec.on{animation:pstp 1s infinite}@keyframes pstp{50%{opacity:.6}}
.pst .row2{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.pst input.inits{font-weight:700;font-size:1.1rem;width:90px;text-transform:uppercase;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg)}
.pst .muted{color:var(--muted);font-size:.9rem}.pst .msg{font-weight:600}.pst .msg.err{color:#b3261e}.pst .msg.ok{color:#2e7d1f}
.pst audio{width:100%;max-width:420px}`;

const initialsOf = (name) => String(name || "").split(/\s+/).filter(Boolean).map((w) => w[0]).join("").toUpperCase().slice(0, 4);
const when = (iso) => new Date(iso).toLocaleString("en-US", { timeZone: "America/Chicago", month: "numeric", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
const audioMime = () => { const o = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]; return window.MediaRecorder ? o.find((m) => MediaRecorder.isTypeSupported(m)) || "" : ""; };
const extOf = (mime) => /mp4|m4a|aac/.test(mime) ? "mp4" : /ogg/.test(mime) ? "ogg" : /mpeg|mp3/.test(mime) ? "mp3" : /wav/.test(mime) ? "wav" : /3gpp/.test(mime) ? "3gp" : "webm";

// A clean printable page of the signed copy (the portal around it is left out). The recording cannot print; its length and the statement do.
export function printAckCopy(a) {
  const w = window.open("", "_blank"); if (!w) return;
  const row = (t) => t.kind === "rule"
    ? `<tr><td class="n">${esc(t.position)}.</td><td>${esc(t.text)}</td><td class="i">${esc(t.initials)}</td></tr>`
    : `<tr><td colspan="2">${esc(t.text)} <b style="float:right;padding-left:12px">${esc(t.amount || "")}</b></td><td class="i">${esc(t.initials)}</td></tr>`;
  w.document.write(`<!DOCTYPE html><html><head><meta charset="utf-8"><title>Signed parking rules - stall ${esc(a.unit)}</title><style>
    body{font:14px/1.45 Arial,sans-serif;color:#111;margin:28px}h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:18px 0 6px}
    table{width:100%;border-collapse:collapse}td{border-bottom:1px solid #ccc;padding:5px 6px;vertical-align:top}td.n{width:28px;text-align:right;color:#555}
    td.i{width:70px;text-align:center;font-family:"Segoe Script","Brush Script MT",cursive;font-size:16px;color:#1b5e20}.m{color:#444}</style></head><body>
    <h1>Parking rules and fines: signed copy</h1>
    <div class="m">2nd Chance Housing · 6622-6626 N Bourbon St, Milwaukee, WI · Stall ${esc(a.unit)}</div>
    <p>Signed by <b>${esc(a.name || "")}</b> on <b>${esc(when(a.signed_at))}</b> (Central time). Initials: <b>${esc(a.initials)}</b>.</p>
    <h2>Parking rules</h2><table>${a.items.filter((i) => i.kind === "rule").map(row).join("")}</table>
    <h2>Violations and fines</h2><p class="m" style="margin:0 0 6px">Towing is at the vehicle owner's expense. Fines are charged to the unit's association account.</p>
    <table>${a.items.filter((i) => i.kind === "fine").map(row).join("")}</table>
    <h2>${a.method === "paper" ? "Statement" : "Recorded statement"}</h2><p>"${esc(a.statement)}"<br><span class="m">${a.method === "paper" ? "Signed on paper; the signed paper is kept on file and on the portal." : `Recorded out loud by the signer (${esc(a.audio_seconds || "")} seconds); the recording is kept on file and on the portal.`}</span></p>
    <p class="m">Full rules: https://2ndchinc.org/documents/parking/ · Record ${esc(a.id)}</p></body></html>`);
  w.document.close(); w.focus(); setTimeout(() => w.print(), 300);
}

export async function mountParkingStatus(el, flash = "") {
  if (!document.getElementById("pst-css")) { const c = document.createElement("style"); c.id = "pst-css"; c.textContent = CSS; document.head.appendChild(c); }
  const [{ data: s, error }, { data: T }, { data: PT }] = await Promise.all([client.rpc("parking_status_mine"), client.rpc("parking_terms_mine"), client.rpc("parking_tags_mine")]);
  if (error || !s) { el.innerHTML = ""; return; }
  const tagsBy = Object.fromEntries(((PT && PT.units) || []).map((u) => [u.unit, u]));
  const terms = (T && T.terms) || [], rules = terms.filter((t) => t.kind === "rule"), fines = terms.filter((t) => t.kind === "fine");
  const ackBy = Object.fromEntries(((T && T.units) || []).map((u) => [u.unit, u.ack]));
  const needSign = ((T && T.units) || []).filter((u) => !u.ack || !u.ack.current).map((u) => u.unit);
  const st = { inits: initialsOf(T && T.name), done: {}, blob: null, mime: "", secs: 0, view: null };
  const live = s.enforce_from && s.today >= s.enforce_from;

  function cardsHtml() {
    const snow = s.snow ? `<div class="snow">❄ Snow removal: move your vehicle out of the lot${s.snow.from ? " by " + esc(when(s.snow.from)) : ""}${s.snow.until ? ". Return after " + esc(when(s.snow.until)) : ". Return after plowing"}.</div>` : "";
    return snow + (s.units || []).map((u) => {
      const vs = u.vehicles || [], cars = vs.filter((v) => v.kind !== "visitor"), answered = vs.length || u.no_vehicle, a = ackBy[u.unit];
      const cls = u.blocked ? "bad" : answered && a && a.current ? "good" : "warn";
      let state;
      if (u.blocked) state = `<div class="no">NO PARKING. Your parking is revoked. A vehicle in stall ${esc(u.stall || u.unit)} is towed. Call ${esc(s.office_phone)}.</div>`;
      else if (!answered) state = `<div class="no">Vehicle not registered.${s.register_by && !live ? ` Register by ${fmtDate(s.register_by)}.` : ""}${live ? " A vehicle here is towed." : ""}</div>`;
      else if (!cars.length) state = `<div class="ok">✓ ${u.no_vehicle ? "No vehicle" : "Visitor only"}.</div>`;
      else state = cars.map((v) => `<div><span class="ok">✓ Registered:</span> ${esc(v.desc)}${v.plate ? " · " + esc(v.plate) : ""}${v.kind === "loaner" && v.loaner_until ? (v.loaner_until < s.today ? ` · <span class="no">loaner EXPIRED ${fmtDate(v.loaner_until)}: extend or remove it</span>` : ` · loaner until ${fmtDate(v.loaner_until)}`) : ""}${v.kind === "loaner" ? `<span class="row2" style="margin-top:4px"><input type="date" data-exd="${esc(v.id)}" min="${esc(s.today)}" style="padding:5px 8px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg)"><button class="btn" type="button" data-ext="${esc(v.id)}">Extend loaner</button><span class="muted" data-exm="${esc(v.id)}"></span></span>` : ""}</div>
          <div class="muted">${v.hanger ? `Mirror tag: <b>${esc(v.hanger)}</b>` : hasTags(u.unit) ? `Mirror tag: hang one of your red tags` : `Mirror tag: coming soon`}</div>`).join("");
      const sign = !T ? "" : a && a.current ? `<div class="row2"><span class="ok">✓ Parking rules signed ${esc(fmtDate(a.signed_at))}.</span><button class="btn" type="button" data-view="${esc(u.unit)}">View my signed copy</button></div>`
        : `<div class="no">Parking rules not signed${a ? " (the rules changed since you signed)" : ""}. Sign below.</div>`;
      const swapped = u.stall && u.stall !== u.unit ? ` <span class="muted">(switch: today stall ${esc(u.stall)})</span>` : "";
      return `<div class="card ${cls}"><div class="big">Your stall: ${esc(u.stall || u.unit)}${swapped}</div>${state}${sign}</div>${tagsHtml(u.unit)}`;
    }).join("");
  }

  // Mirror hang tags: 2 red resident tags + 1 blue guest tag per unit. The guest tag can be lent to another unit (up to PT.max_days);
  // only the lender marks it returned, then the borrower is asked to send a thank-you. Database: 20261118630000_parking_tags_guest_loans.sql
  const tagName = (code) => { const m = /^G(.+?)(B)?$/.exec(code); return m ? "Guest " + m[1] + (m[2] ? " (2nd)" : "") : code; };
  function hasTags(unit) { const t = tagsBy[unit]; return !!(t && t.tags.some((x) => x.issued_at && x.status === "active" && !x.collect)); }
  function tagsHtml(unit) {
    const t = tagsBy[unit]; if (!t) return "";
    const toConfirm = t.tags.filter((x) => x.issued_at && !x.received_at && x.status === "active" && !x.collect);
    const confirmBox = toConfirm.length ? `<div class="step"><b>The office handed you ${toConfirm.length} parking tag${toConfirm.length === 1 ? "" : "s"}:</b> ${toConfirm.map((x) => esc(tagName(x.code)) + (x.kind === "guest" ? " (blue)" : " (red)")).join(", ")}.
        <div class="row2" style="margin-top:4px"><button class="btn primary" type="button" data-trecv="${esc(unit)}">I received my tags</button><span class="muted" data-tm="recv-${esc(unit)}"></span></div></div>` : "";
    const got = t.tags.filter((x) => x.received_at).map((x) => x.received_at).sort()[0];
    const feeLine = t.tags.some((x) => x.issued_at) ? `<div class="muted" style="margin-top:6px">${got ? `You confirmed receiving your tags ${fmtDate(got)}. ` : ""}The tags belong to the unit: give them back at move-out. A lost tag costs ${esc(PT.replace_fee || 25)} to replace: call ${esc(s.office_phone)}.</div>` : "";
    const res = t.tags.filter((x) => x.kind === "resident"), guest = t.tags.filter((x) => x.kind === "guest");
    const late = (d) => d < PT.today;
    const resLine = res.length ? `<div><b>Red resident tags:</b> ${res.map((x) => esc(x.code) + (x.status === "lost" ? ` <span class="no">(lost, not valid)</span>` : "")).join(", ")}.
      <span class="muted">Hang one on the mirror whenever you park.</span></div>` : "";
    const guestLines = guest.map((g) => {
      if (g.status === "lost") return `<div><b>Blue guest tag ${esc(tagName(g.code))}:</b> <span class="no">marked lost, not valid.</span> Call ${esc(s.office_phone)} for a new one.</div>`;
      if (g.loan) return `<div><b>Blue guest tag ${esc(tagName(g.code))}:</b> lent to <b>Unit ${esc(g.loan.to_unit)}</b> until ${fmtDate(g.loan.lent_until)}${late(g.loan.lent_until) ? ` <span class="no">(past due: ask for it back)</span>` : ""}.
          <div class="row2" style="margin-top:4px"><button class="btn" type="button" data-tret="${esc(g.loan.id)}">I got it back: mark returned</button><span class="muted" data-tm="${esc(g.loan.id)}"></span></div></div>`;
      const max = new Date(PT.today + "T12:00"); max.setDate(max.getDate() + PT.max_days);
      const opts = (PT.all_units || []).filter((x) => x !== unit).map((x) => `<option value="${esc(x)}">Unit ${esc(x)}</option>`).join("");
      return `<div><b>Blue guest tag ${esc(tagName(g.code))}:</b> with you. Your guest hangs it on the mirror and parks only in your stall.
        <details style="margin-top:4px"><summary>Lend it to a neighbor</summary>
          <div class="row2" style="margin-top:6px"><select data-tto="${esc(g.code)}" style="padding:6px 8px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg)"><option value="">Lend to…</option>${opts}</select>
          <label class="muted">until <input type="date" data-tun="${esc(g.code)}" min="${esc(PT.today)}" max="${max.toISOString().slice(0, 10)}" style="padding:5px 8px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg)"></label>
          <button class="btn primary" type="button" data-tlend="${esc(g.code)}">Record the loan</button><span class="muted" data-tm="${esc(g.code)}"></span></div>
          <div class="muted">Up to ${esc(PT.max_days)} days. While they have it, their guest parks only in their own stall, and your stall has no guest tag. You mark it returned when you get it back.</div></details></div>`;
    }).join("");
    const borrowed = t.borrowed.map((b) => `<div><b>You have Unit ${esc(b.from_unit)}'s guest tag</b> (${esc(tagName(b.code))}) until ${fmtDate(b.lent_until)}${late(b.lent_until) ? ` <span class="no">PAST DUE: it is no longer valid here. Give it back to Unit ${esc(b.from_unit)} now.</span>` : ". Your guest may park in your stall with it. Give it back by then; Unit " + esc(b.from_unit) + " marks it returned."}</div>`).join("");
    const thanks = t.thank.map((x) => `<div class="step"><b>Unit ${esc(x.from_unit)} got their guest tag back.</b> Send them a thank-you? <span class="muted">(It goes to Unit ${esc(x.from_unit)} by email. Optional note:)</span>
        <textarea data-tnote="${esc(x.id)}" rows="2" maxlength="500" placeholder="Thanks for the guest tag!" style="width:100%;max-width:480px;margin-top:4px;padding:6px 8px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg);font:inherit"></textarea>
        <div class="row2"><button class="btn primary" type="button" data-tthx="${esc(x.id)}">Send thank-you</button><button class="btn" type="button" data-tskip="${esc(x.id)}">Not now</button><span class="muted" data-tm="${esc(x.id)}"></span></div></div>`).join("");
    if (!resLine && !guestLines && !borrowed && !thanks) return "";
    return `<div class="box"><h3>Parking tags: Unit ${esc(unit)}</h3>${confirmBox}${resLine}${guestLines}${borrowed}${thanks}${feeLine}</div>`;
  }

  function termRow(t, signing, initials) {
    const btn = signing ? (st.done[t.id] ? `<span class="ini done">${esc(st.inits)}</span>` : `<button class="ini" type="button" data-ini="${esc(t.id)}">Initial</button>`)
      : initials ? `<span class="ini done">${esc(initials)}</span>` : "<span></span>";
    const key = t.id ? ` data-t="${esc(t.id)}"` : "";
    return t.kind === "rule"
      ? `<div class="term"${key}><span class="n">${esc(t.position)}.</span><span>${esc(!signing && !initials && Object.keys(tagsBy).some(hasTags) ? String(t.text).replace(/\s*\(hangers coming soon\)/i, "") : t.text)}</span>${btn}</div>`
      : `<div class="term fine"${key}><span>${esc(t.text)}</span><span class="amt">${esc(t.amount || "")}</span>${btn}</div>`;
  }

  function signHtml() {
    const left = terms.filter((t) => !st.done[t.id]).length, ready = left === 0;
    const script = `I${T.name ? ", " + esc(T.name) + "," : ""} ${esc(String(T.statement || "").replace(/^I /, ""))}`;
    return `<div class="box"><h3>Sign the parking rules${needSign.length > 1 ? " for stalls " + needSign.map(esc).join(", ") : ""}</h3>
      <div class="step"><b>Step 1.</b> Your initials: <input class="inits" id="pstInits" maxlength="6" value="${esc(st.inits)}"> Press <b>Initial</b> next to every rule and every fine.</div>
      <h3>Parking rules</h3><div class="terms">${rules.map((t) => termRow(t, true)).join("")}</div>
      <h3>Violations and fines</h3><p class="muted" style="margin:0">Towing is at the vehicle owner's expense. Fines are charged to the unit's association account.</p>
      <div class="terms">${fines.map((t) => termRow(t, true)).join("")}</div>
      <div class="step"><b>Step 2.</b> Record your voice: press Record and read this out loud.
        <p class="script">"${script}"</p>
        <div class="row2"><button class="rec" type="button" id="pstRec" ${ready ? "" : "disabled style=\"opacity:.45;cursor:not-allowed\""}>● Record</button>
          <span class="muted" id="pstRecMsg">${ready ? "" : `Unlocks after you initial all ${terms.length} items (${left} left).`}</span></div>
        <div id="pstPlay"></div></div>
      <div class="step"><b>Step 3.</b> <button class="btn primary" type="button" id="pstSubmit" ${ready && st.blob ? "" : "disabled"}>Submit my signature</button>
        <span class="muted">${ready && st.blob ? "You get an email copy for your records." : "Unlocks after you record."}</span></div>
      <div class="msg" id="pstMsg"></div>
      <p class="muted" style="margin:0">Full rules: <a href="/documents/parking/" target="_blank" rel="noopener">Parking Agreement</a>. Questions: ${esc(s.office_phone)}.</p></div>`;
  }

  function readHtml() {
    return `<details class="box"><summary><b>Parking rules and fines</b></summary>
      <div class="terms">${rules.map((t) => termRow(t, false)).join("")}</div><h3>Violations and fines</h3>
      <div class="terms">${fines.map((t) => termRow(t, false)).join("")}</div>
      <p class="muted" style="margin:0">Full rules: <a href="/documents/parking/" target="_blank" rel="noopener">Parking Agreement</a>. Questions: ${esc(s.office_phone)}.</p></details>`;
  }

  function viewHtml(a) {
    const r = a.items.filter((i) => i.kind === "rule"), f = a.items.filter((i) => i.kind === "fine");
    return `<div class="box" id="pstView"><h3>My signed parking rules: stall ${esc(a.unit)}</h3>
      <p style="margin:0">Signed by ${esc(a.name || "")} on ${esc(when(a.signed_at))} (Central time)${a.current ? "" : ". <b>The rules changed since. Please sign the new version.</b>"}</p>
      <div class="terms">${r.map((t) => termRow(t, false, t.initials)).join("")}</div><h3>Violations and fines</h3>
      <div class="terms">${f.map((t) => termRow(t, false, t.initials)).join("")}</div>
      ${a.method === "paper" ? `<p style="margin:0">Signed on paper: <i>"${esc(a.statement)}"</i> <a href="#" id="pstScan">View the signed paper</a></p>` : `<p style="margin:0">Your recorded statement (${esc(a.audio_seconds || "")} seconds): <i>"${esc(a.statement)}"</i></p><audio controls id="pstAud"></audio>`}
      <div class="row2"><button class="btn primary" type="button" id="pstPrint">Print</button><button class="btn" type="button" id="pstClose">Close</button></div></div>`;
  }



  function draw() {
    el.innerHTML = `<div class="pst">${flash}${cardsHtml()}${st.view ? viewHtml(st.view) : ""}${T && needSign.length ? signHtml() : T ? readHtml() : ""}</div>`;
    wire();
  }

  function wire() {
    const $ = (id) => el.querySelector("#" + id);
    el.querySelectorAll("[data-view]").forEach((b) => b.onclick = async () => {
      st.view = ackBy[b.dataset.view]; draw();
      $("pstView").scrollIntoView({ behavior: "smooth", block: "start" });
      const { data } = await client.storage.from("parking-acks").createSignedUrl(st.view.method === "paper" ? st.view.scan_path : st.view.audio_path, 3600);
      if (data && $("pstAud")) $("pstAud").src = data.signedUrl;
      if (data && $("pstScan")) { $("pstScan").href = data.signedUrl; $("pstScan").target = "_blank"; $("pstScan").rel = "noopener"; }
    });
    if ($("pstClose")) $("pstClose").onclick = () => { st.view = null; draw(); };
    el.querySelectorAll("[data-ext]").forEach((b) => b.onclick = async () => {
      const id = b.dataset.ext, d = el.querySelector(`[data-exd="${id}"]`).value, m = el.querySelector(`[data-exm="${id}"]`);
      if (!d) { m.textContent = "Choose the new return date."; return; }
      b.disabled = true;
      const { error: e } = await client.rpc("vehicle_loaner_extend", { p_id: id, p_until: d });
      if (e) { m.textContent = await errorText(e); b.disabled = false; return; }
      client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
      mountParkingStatus(el, `<div class="card good"><span class="ok">✓ Loaner extended to ${fmtDate(d)}.</span></div>`);
    });
    const tmsg = (k, t) => { const m = el.querySelector(`[data-tm="${k}"]`); if (m) m.textContent = t; };
    const tagDo = async (b, key, rpc, args, done) => {
      b.disabled = true; tmsg(key, "Saving…");
      const { error: e } = await client.rpc(rpc, args);
      if (e) { tmsg(key, await errorText(e)); b.disabled = false; return; }
      client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
      mountParkingStatus(el, `<div class="card good"><span class="ok">✓ ${done}</span></div>`);
    };
    el.querySelectorAll("[data-tlend]").forEach((b) => b.onclick = () => {
      const c = b.dataset.tlend, to = el.querySelector(`[data-tto="${c}"]`).value, un = el.querySelector(`[data-tun="${c}"]`).value;
      if (!to || !un) { tmsg(c, "Choose the unit and the return date."); return; }
      tagDo(b, c, "parking_tag_lend", { p_code: c, p_to_unit: to, p_until: un }, `Guest tag lent to Unit ${esc(to)} until ${fmtDate(un)}.`);
    });
    el.querySelectorAll("[data-trecv]").forEach((b) => b.onclick = () => tagDo(b, "recv-" + b.dataset.trecv, "parking_tags_receive", { p_unit: b.dataset.trecv }, "Thank you. Your parking tags are recorded as received."));
    el.querySelectorAll("[data-tret]").forEach((b) => b.onclick = () => tagDo(b, b.dataset.tret, "parking_tag_return", { p_loan: b.dataset.tret }, "Guest tag marked returned."));
    el.querySelectorAll("[data-tthx]").forEach((b) => b.onclick = () => tagDo(b, b.dataset.tthx, "parking_tag_thank",
      { p_loan: b.dataset.tthx, p_note: el.querySelector(`[data-tnote="${b.dataset.tthx}"]`).value, p_send: true }, "Thank-you sent."));
    el.querySelectorAll("[data-tskip]").forEach((b) => b.onclick = () => tagDo(b, b.dataset.tskip, "parking_tag_thank", { p_loan: b.dataset.tskip, p_note: null, p_send: false }, "OK."));
    if ($("pstPrint")) $("pstPrint").onclick = () => printAckCopy(st.view);
    if ($("pstInits")) $("pstInits").oninput = (e) => { st.inits = e.target.value.toUpperCase().replace(/[^A-Z.\- ]/g, ""); };
    el.querySelectorAll("[data-ini]").forEach((b) => b.onclick = () => {
      if (String(st.inits).replace(/[^A-Z]/g, "").length < 2) { $("pstMsg").className = "msg err"; $("pstMsg").textContent = "Type your initials first (Step 1)."; $("pstInits").focus(); return; }
      const id = b.dataset.ini, y = b.getBoundingClientRect().top;
      st.done[id] = new Date().toISOString(); draw();
      if (!el.querySelector("[data-ini]")) { $("pstRec") && $("pstRec").scrollIntoView({ behavior: "smooth", block: "center" }); return; }
      const row = el.querySelector(`[data-t="${id}"] .ini`); if (row) window.scrollBy(0, row.getBoundingClientRect().top - y);   // keep the page still
    });
    if ($("pstRec")) $("pstRec").onclick = () => record($("pstRec"));
    if (st.blob && $("pstPlay")) $("pstPlay").innerHTML = `<audio controls src="${URL.createObjectURL(st.blob)}"></audio><div class="muted">Listen back. Press Record again to redo it.</div>`;
    if ($("pstSubmit")) $("pstSubmit").onclick = () => submit($("pstSubmit"));
  }

  let recorder = null, chunks = [], t0 = 0, stream = null;
  async function record(btn) {
    const msg = el.querySelector("#pstRecMsg");
    if (recorder && recorder.state === "recording") { recorder.stop(); return; }
    const mime = audioMime();
    if (!mime || !navigator.mediaDevices?.getUserMedia) {   // no in-browser recorder: use the phone's voice recorder
      const f = document.createElement("input"); f.type = "file"; f.accept = "audio/*"; f.setAttribute("capture", "");
      f.onchange = () => { const file = f.files[0]; if (!file) return; const a = new Audio(URL.createObjectURL(file));
        a.onloadedmetadata = () => { st.blob = file; st.mime = file.type || "audio/mp4"; st.secs = isFinite(a.duration) ? a.duration : 5; draw(); }; };
      f.click(); return;
    }
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); }
    catch { msg.textContent = "Allow the microphone for this site, then try again."; return; }
    chunks = []; recorder = new MediaRecorder(stream, { mimeType: mime, audioBitsPerSecond: 48000 });
    recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    recorder.onstop = () => {
      stream.getTracks().forEach((t) => t.stop());
      const secs = (Date.now() - t0) / 1000, type = mime.split(";")[0];
      if (secs < 3) { draw(); el.querySelector("#pstRecMsg").textContent = "Too short. Read the whole statement."; return; }
      st.secs = secs; st.mime = type; st.blob = new Blob(chunks, { type }); draw();
      el.querySelector("#pstSubmit") && el.querySelector("#pstSubmit").scrollIntoView({ behavior: "smooth", block: "center" });
    };
    recorder.start(); t0 = Date.now(); btn.classList.add("on"); btn.textContent = "■ Stop"; msg.textContent = "Recording… read the statement, then press Stop.";
    setTimeout(() => { if (recorder && recorder.state === "recording") recorder.stop(); }, 90000);
  }

  async function submit(btn) {
    const msg = el.querySelector("#pstMsg"); btn.disabled = true; msg.className = "msg"; msg.textContent = "Saving…";
    try {
      const { data: ses } = await client.auth.getSession(), uid = ses?.session?.user?.id;   // folder = own user id (storage policy)
      if (!uid) throw new Error("You were signed out. Sign in again, then submit.");
      const path = `${uid}/${crypto.randomUUID()}.${extOf(st.mime)}`;
      const up = await client.storage.from("parking-acks").upload(path, st.blob, { contentType: st.mime || "audio/webm" });
      if (up.error) throw new Error("Your recording didn't upload. Check your connection and try again.");
      const items = terms.map((t) => ({ id: t.id, at: st.done[t.id] }));
      for (const unit of needSign) {
        const { error: e } = await client.rpc("parking_ack_submit", { p_unit: unit, p_initials: st.inits, p_items: items, p_audio_path: path,
          p_audio_seconds: Math.round(st.secs * 10) / 10, p_user_agent: navigator.userAgent });
        if (e) throw new Error(await errorText(e));
      }
      client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
      await mountParkingStatus(el, `<div class="card good"><span class="ok">✓ Signed. A copy is on its way to your email.</span></div>`);
      el.scrollIntoView({ behavior: "smooth", block: "start" });
    } catch (e) { msg.className = "msg err"; msg.textContent = e.message; btn.disabled = false; }
  }

  draw();
}
