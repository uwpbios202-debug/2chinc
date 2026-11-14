// Snow removal section of the contractor page: sign the agreement, press the move-your-vehicle button,
// finish a visit with before and after photos, propose junk removal. New file on purpose (portal.js is cached for hours).
import { client, esc, money, errorText } from "/assets/portal/portal.js";

const PHOTO_TYPES = ["image/jpeg", "image/png", "image/webp", "image/heic"], PHOTO_MAX = 10 * 1024 * 1024;
const STATUS = { notified: "In progress", proposed: "Waiting for office approval", junk_approved: "Approved: do the work", declined: "Not approved", done: "Waiting for office review", returned: "Sent back: please fix", approved: "Approved, payment due", paid: "Paid" };
const stamp = (t) => t ? new Date(t).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";
const rpc = async (fn, args) => { const { data, error } = await client.rpc(fn, args); if (error) throw new Error(await errorText(error)); return data; };

async function upload(files, visitId) {
  const paths = [];
  for (const f of files) {
    const type = f.type || (/\.heic$/i.test(f.name) ? "image/heic" : "");
    if (!PHOTO_TYPES.includes(type)) throw new Error(`"${f.name}" isn't a JPG, PNG, WebP or HEIC photo.`);
    if (f.size > PHOTO_MAX) throw new Error(`"${f.name}" is over 10 MB.`);
    const path = `${visitId}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${type.split("/")[1].replace("jpeg", "jpg")}`;
    const { error } = await client.storage.from("snow-photos").upload(path, f, { contentType: type });
    if (error) throw new Error(`"${f.name}" couldn't be uploaded. Check your connection and try again.`);
    paths.push(path);
  }
  return paths;
}

const winText = (v) => v.window_start ? new Date(v.window_start).toLocaleString("en-US", { timeZone: "America/Chicago", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) + " to " + new Date(v.window_end).toLocaleTimeString("en-US", { timeZone: "America/Chicago", hour: "numeric", minute: "2-digit" }) : "";
const terms = (a) => a.terms.map((t) => `<p><b>${esc(t.h)}</b><br>${esc(t.p)}</p>`).join("");

function visitCard(v) {
  const open = ["notified", "junk_approved", "returned"].includes(v.status);
  return `<div class="panel job" data-visit="${esc(v.id)}">
    <div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><div><h2 style="margin:0">${v.kind === "junk" ? "Junk removal" : "Snow push"} · ${esc(stamp(v.created_at))}</h2>
      <div class="meta">${v.notice_count != null ? `${v.notice_count} households emailed ${esc(stamp(v.notice_sent_at))} · stalls empty ${esc(winText(v))}` : v.kind === "snow" ? "No vehicle notice sent" : esc(v.description || "")}${v.amount != null ? " · " + money(v.amount) : ""}${v.paid_on ? " · paid " + esc(v.paid_on) : ""}</div></div>
      <span class="pill2 ${v.status === "paid" ? "done" : ["returned", "proposed", "done"].includes(v.status) ? "warn" : ""}">${esc(STATUS[v.status] || v.status)}</span></div>
    ${v.office_note ? `<div class="notes"><b>Office:</b> ${esc(v.office_note)}</div>` : ""}
    ${v.kind === "junk" && v.description && v.notice_count == null ? `<p>${esc(v.description)}</p>` : ""}
    ${open ? `<div class="row3">
      ${v.kind === "snow" ? `<label>Before photos<input type="file" data-before accept="image/*" multiple></label>` : ""}
      <label>After photos<input type="file" data-after accept="image/*" multiple></label>
      <label>Note (optional)<input data-note maxlength="500" placeholder="Areas cleared, salt used, anything for the office"></label>
      <button class="btn primary" type="button" data-finish>Finish this visit</button></div><span class="msg" data-msg></span>` : ""}
  </div>`;
}

export async function mountSnow(el) {
  let d;
  try { d = await rpc("snow_vendor_overview"); } catch (_) { el.hidden = true; return; }
  if (!d.agreement) { el.hidden = true; return; }
  el.hidden = false;
  const a = d.agreement, active = a.status === "active";
  const sign = !a.vendor_signed_at && !a.can_sign ? `<p class="meta">Waiting for ${esc(a.signer_name)} to sign for the vendor. Only they can sign; office staff cannot sign for anyone.</p>`
    : !a.vendor_signed_at ? `<div class="notes" style="white-space:normal"><b>Sign to begin.</b> Read the agreement above, then type your full name (${esc(a.signer_name)}) and sign.
      <div class="row3"><label>Your full name<input data-signname maxlength="120" autocomplete="off"></label><button class="btn primary" type="button" data-sign>I agree and sign</button></div><span class="msg" data-msg></span></div>`
    : `<p class="meta">You signed ${esc(stamp(a.vendor_signed_at))} as ${esc(a.vendor_signed_name)}. ${a.client_signed_at ? `Signed for ROCA1 by ${esc(a.client_signed_name)}, ${esc(a.client_signer_title)}, ${esc(stamp(a.client_signed_at))}.` : `Waiting for ${esc(a.client_signer_name)}, ${esc(a.client_signer_title)}, to sign for ROCA1.`}</p>`;
  el.innerHTML = `<div class="panel" id="snowTop">
    <h2 style="margin-top:0">Snow removal · Winter ${esc(a.season)}</h2>
    <p class="meta">${money(a.rate)} per completed push at 6622 &amp; 6626 N Bourbon St · Owed to you (approved): <b>${money(d.owed)}</b> · Waiting for review: ${money(d.pending)} · Paid so far: ${money(d.paid_total)} · ROCA1 pays by Zelle.</p>
    <details${a.vendor_signed_at ? "" : " open"}><summary>Agreement</summary>${terms(a)}</details>${sign}
    ${active ? `<div class="panel" style="margin-top:12px"><b>Warn the tenants before a push</b>
      <p class="meta">Tell residents when their stall must be empty. Your schedule can change, so choose the window each time; you can send another email if it moves. Stall numbers match the unit numbers. Vehicles left in the lot may be towed.</p>
      <div class="row3"><label>Date<input type="date" data-wdate></label><label>Stalls must be empty from<input type="time" data-wfrom value="07:00"></label><label>until<input type="time" data-wto value="10:00"></label></div>
      <div class="meta" style="margin-top:8px">Stalls to notify <button class="linkbtn" type="button" data-allstalls>all</button> <button class="linkbtn" type="button" data-nostalls>none</button></div>
      <div class="stalls" data-stalls></div>
      <div class="row3"><button class="btn primary" type="button" data-notify style="font-size:1.05rem;padding:12px 18px">Email these tenants now</button>
      <button class="btn" type="button" data-nonotice>Log a push without an email</button></div>
      <span class="msg" data-topmsg></span></div>
      <details style="margin-top:8px"><summary>Propose junk removal (needs office approval)</summary><div class="row3">
        <label>What you found and where<input data-jdesc maxlength="500"></label>
        <label>Photos<input type="file" data-jphotos accept="image/*" multiple></label>
        <button class="btn" type="button" data-jsend>Send to the office</button></div><span class="msg" data-jmsg></span></details>` : ""}
  </div>${d.visits.map(visitCard).join("")}`;

  const top = el.querySelector("[data-topmsg]");
  if (active) {
    const stalls = await rpc("snow_vendor_stalls").catch(() => []);
    el.querySelector("[data-stalls]").innerHTML = stalls.map((u) => `<label class="stall"><input type="checkbox" value="${esc(u)}" checked> ${esc(u)}</label>`).join("");
    el.querySelector("[data-wdate]").value = new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
    el.querySelector("[data-allstalls]").onclick = () => el.querySelectorAll("[data-stalls] input").forEach((i) => { i.checked = true; });
    el.querySelector("[data-nostalls]").onclick = () => el.querySelectorAll("[data-stalls] input").forEach((i) => { i.checked = false; });
  }
  const say = (n, t, bad) => { if (n) { n.className = "msg " + (bad ? "err" : "ok"); n.textContent = t; } };
  const reload = async () => { await mountSnow(el); };
  const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});

  el.querySelector("[data-sign]")?.addEventListener("click", async (e) => {
    const m = e.target.closest(".notes").querySelector("[data-msg]"); e.target.disabled = true;
    try { await rpc("snow_vendor_sign", { p_name: el.querySelector("[data-signname]").value }); flush(); await reload(); } catch (err) { say(m, err.message, true); e.target.disabled = false; }
  });
  // "2026-10-27" + "07:00" in Chicago time -> an instant
  const chicago = (date, time) => {
    const want = Date.parse(date + "T" + time + ":00Z");
    let t = want;
    for (let i = 0; i < 3; i++) {
      const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(t)).map((x) => [x.type, x.value]));
      t += want - Date.parse(`${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:00Z`);
    }
    return new Date(t).toISOString();
  };
  const newVisit = async (b, notify) => {
    let args = { p_notify: notify, p_from: null, p_to: null, p_units: null };
    if (notify) {
      const d = el.querySelector("[data-wdate]").value, f = el.querySelector("[data-wfrom]").value, t = el.querySelector("[data-wto]").value;
      const units = [...el.querySelectorAll("[data-stalls] input:checked")].map((i) => i.value);
      if (!d || !f || !t) return say(top, "Choose the date and the from and until times.", true);
      if (!units.length) return say(top, "Tick at least one stall.", true);
      const all = el.querySelectorAll("[data-stalls] input").length === units.length;
      args = { p_notify: true, p_from: chicago(d, f), p_to: chicago(d, t), p_units: all ? null : units };
      if (b.dataset.armed !== "1") { b.dataset.armed = "1"; b.dataset.label = b.textContent; b.textContent = `Press again to email ${all ? "everyone" : units.length + " stall(s)"} now`; setTimeout(() => { b.dataset.armed = ""; b.textContent = b.dataset.label; }, 6000); return; }
    }
    b.disabled = true; say(top, "Sending…");
    try { const r = await rpc("snow_vendor_new_visit", args); if (notify) await flush(); await reload(); say(el.querySelector("[data-topmsg]"), notify ? `Emailed ${r.emailed} households. Finish the visit below when you are done.` : "Push logged. Finish it below when you are done."); }
    catch (err) { say(top, err.message, true); b.disabled = false; b.dataset.armed = ""; if (b.dataset.label) b.textContent = b.dataset.label; }
  };
  el.querySelector("[data-notify]")?.addEventListener("click", (e) => newVisit(e.currentTarget, true));
  el.querySelector("[data-nonotice]")?.addEventListener("click", (e) => newVisit(e.currentTarget, false));
  el.querySelector("[data-jsend]")?.addEventListener("click", async (e) => {
    const m = el.querySelector("[data-jmsg]"); e.target.disabled = true; say(m, "Sending…");
    try {
      const files = [...el.querySelector("[data-jphotos]").files]; if (!files.length) throw new Error("Add at least one photo.");
      const id = crypto.randomUUID(), paths = await upload(files, id);
      await rpc("snow_vendor_junk_propose", { p_id: id, p_description: el.querySelector("[data-jdesc]").value, p_photos: paths }); flush(); await reload();
    } catch (err) { say(m, err.message, true); e.target.disabled = false; }
  });
  el.querySelectorAll("[data-finish]").forEach((b) => b.addEventListener("click", async () => {
    const c = b.closest("[data-visit]"), m = c.querySelector("[data-msg]"), id = c.dataset.visit; b.disabled = true; say(m, "Uploading photos…");
    try {
      const before = [...(c.querySelector("[data-before]")?.files || [])], after = [...c.querySelector("[data-after]").files];
      const [pb, pa] = [await upload(before, id), await upload(after, id)];
      await rpc("snow_vendor_finish", { p_id: id, p_note: c.querySelector("[data-note]").value, p_before: pb, p_after: pa }); flush(); await reload();
    } catch (err) { say(m, err.message, true); b.disabled = false; }
  }));
}
