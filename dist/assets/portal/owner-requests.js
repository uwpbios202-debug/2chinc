// Owner requests (owner portal #requests): report a problem with the common property or a unit, follow it, and read the board's
// repair priority list. Database: supabase/migrations/20261112070000_owner_requests.sql.
import { client, esc, fmtDate, errorText, ctDate } from "/assets/portal/portal.js";

const PHOTO_TYPES = ["image/jpeg", "image/png", "image/webp", "image/heic"], PHOTO_MAX = 10 * 1024 * 1024;

const CSS = `
.or{display:grid;gap:14px}.or-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.or h2{margin:0 0 6px;font-size:1.2rem}.or-sub{color:#5b6573;font-size:.88rem;margin:0}
.or-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin-top:10px}
.or-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}.or-form .wide{grid-column:1/-1}
.or-form input,.or-form select,.or-form textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.or-checks{display:flex;gap:18px;flex-wrap:wrap}.or-checks label{display:flex;gap:6px;align-items:center;color:#1b2430;font-size:.95rem}.or-checks input{width:auto}
.or-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:10px 20px;font-weight:700;cursor:pointer}.or-btn:disabled{opacity:.5}
.or-link{background:none;border:0;color:#2e7d1f;font-weight:600;cursor:pointer;padding:0;text-decoration:underline}
.or-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.or-pill.new,.or-pill.reviewing{background:#fff3cd;color:#7a5200}.or-pill.declined,.or-pill.withdrawn{background:#eee;color:#555}.or-pill.urgent,.or-pill.emergency{background:#fde7e7;color:#b3261e}
.or-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.or-msg.err{color:#b3261e}.or-msg.ok{color:#2e7d1f}
.or-warn{background:#fde7e7;border-radius:8px;padding:8px 10px;font-size:.9rem;color:#7a1c14}
.or table{width:100%;border-collapse:collapse;font-size:.9rem}.or th{text-align:left;font-size:.72rem;letter-spacing:.05em;text-transform:uppercase;color:#5b6573;padding:6px;border-bottom:1px solid #d9dfd6}
.or td{padding:7px 6px;border-bottom:1px solid #eef1ec;vertical-align:top}.or td.n{text-align:right;white-space:nowrap}
.or-upd{border-left:3px solid #d9dfd6;margin:6px 0 0 4px;padding:2px 10px;font-size:.88rem}`;

const STATUS = { new: "Received", reviewing: "Being reviewed", ranked: "On the priority list", approved: "Approved", scheduled: "Scheduled", done: "Done", declined: "Not approved", withdrawn: "Withdrawn" };
const URG = { emergency: "Emergency", urgent: "Urgent", normal: "Normal", wish: "Nice to have" };
const WHERE = { "6622": "6622 N Bourbon St", "6626": "6626 N Bourbon St", both: "Both buildings", my_unit: "Inside my unit" };
const money = (n) => n == null ? "not evaluated" : Number(n).toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });

export async function mountOwnerRequests(el) {
  if (!document.getElementById("or-css")) { const s = document.createElement("style"); s.id = "or-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="or-sub">Loading…</p>`;
  const { data: D, error } = await client.rpc("owner_requests_mine");
  if (error) { el.innerHTML = `<p class="or-msg err">${esc(await errorText(error))}</p>`; return; }
  const cats = D.categories || [], units = D.units || [], reqs = D.requests || [];
  el.innerHTML = `<div class="or">
    <div class="or-warn"><b>Emergency?</b> Flooding, a gas smell, no heat in winter, a fire or a safety hazard: call the office right away at (262) 236-5443. For a fire or a gas smell, leave first and call 911. Don't wait for a request.</div>
    <div class="or-card"><h2>New request</h2>
      <p class="or-sub">Report a problem with the shared property (both buildings) or inside your own unit. The board ranks repairs on the priority list below. Repairs to protect the common property are paid by ROCA1 or, when an owner is responsible, assessed to that owner by a board vote. A request is never a charge by itself.</p>
      <form class="or-form" id="orForm" novalidate>
        <label>What kind of problem is it?<select id="orCat"><option value="">Choose…</option>${cats.map((c) => `<option value="${esc(c.code)}">${esc(c.label)}</option>`).join("")}</select></label>
        <label id="orWhereBox">Where is it?<select id="orWhere"><option value="both">Both buildings / not sure</option><option value="6626">6626 N Bourbon St</option><option value="6622">6622 N Bourbon St</option></select></label>
        <label id="orUnitBox" hidden>Which unit?<select id="orUnit">${units.map((u) => `<option value="${esc(u)}">Unit ${esc(u)}</option>`).join("")}</select></label>
        <label>How urgent?<select id="orUrg"><option value="normal">Normal</option><option value="urgent">Urgent: it is getting worse or causing damage</option><option value="wish">Nice to have</option><option value="emergency">Emergency (also call the office)</option></select></label>
        <label class="wide">What needs attention?<input id="orSubject" maxlength="150" placeholder="e.g. Roof leaks over the east stairwell"></label>
        <label class="wide">Describe it<textarea id="orDesc" rows="5" maxlength="5000" placeholder="Where it is, when it started, anything you have noticed"></textarea></label>
        <div class="wide or-checks"><label><input type="checkbox" id="orSafety"> It is a safety or health hazard</label><label><input type="checkbox" id="orInsp"> A housing inspector has noted it</label></div>
        <label class="wide">Photos (up to 6, optional: JPG, PNG, WebP or HEIC, 10 MB each)<input id="orPhotos" type="file" accept="image/jpeg,image/png,image/webp,image/heic,.heic" multiple></label>
        <div class="wide"><button class="or-btn" type="button" id="orSend">Send request</button><div class="or-msg" id="orMsg" role="status"></div></div>
      </form></div>
    <div class="or-card"><h2>Your requests</h2>${reqs.length ? reqs.map(reqCard).join("") : `<p class="or-sub">You haven't sent a request yet.</p>`}</div>
    <div class="or-card"><h2>Repair priority list</h2>
      <p class="or-sub">The board's ranking of repairs for both buildings, with estimates. Rank 1 is first. "Not evaluated" means no bid yet. Estimates are not charges.</p>
      <div style="overflow-x:auto"><table><tr><th>Rank</th><th>Repair</th><th class="n">Estimate</th><th>Status</th></tr>${(D.priorities || []).map((p) =>
        `<tr><td>${esc(p.rank)}</td><td><b>${esc(p.title)}</b>${p.urgent ? ` <span class="or-pill urgent">Urgent</span>` : ""}<div class="or-sub">${esc(p.detail || "")}</div></td><td class="n">${money(p.estimate)}</td><td>${esc(p.status === "open" ? "Open" : p.status === "scheduled" ? "Scheduled" : "Done")}</td></tr>`).join("")}</table></div></div></div>`;

  const $ = (id) => el.querySelector("#" + id), msg = (t, cls) => { $("orMsg").className = "or-msg " + (cls || ""); $("orMsg").textContent = t; };
  $("orCat").onchange = () => { const unit = (cats.find((c) => c.code === $("orCat").value) || {}).scope === "unit"; $("orWhereBox").hidden = unit; $("orUnitBox").hidden = !unit; };
  $("orSend").onclick = async () => {
    const btn = $("orSend"); btn.disabled = true; msg("Sending…");
    try {
      const cat = cats.find((c) => c.code === $("orCat").value); if (!cat) throw new Error("Choose what kind of problem it is.");
      const files = [...$("orPhotos").files], paths = [];
      if (files.length > 6) throw new Error("Please choose 6 photos or fewer.");
      const typeOf = (f) => f.type || (/\.heic$/i.test(f.name) ? "image/heic" : "");
      for (const f of files) {
        if (!PHOTO_TYPES.includes(typeOf(f))) throw new Error(`"${f.name}" isn't a JPG, PNG, WebP or HEIC photo.`);
        if (f.size > PHOTO_MAX) throw new Error(`"${f.name}" is over 10 MB. Choose a smaller photo.`);
      }
      const folder = files.length ? await ownerFolder() : null;
      for (const f of files) {
        const type = typeOf(f), path = `${folder}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${type.split("/")[1].replace("jpeg", "jpg")}`;
        const { error: uErr } = await client.storage.from("owner-requests").upload(path, f, { contentType: type });
        if (uErr) throw new Error(`"${f.name}" couldn't be uploaded. Check your connection and try again.`);
        paths.push(path);
      }
      const { data, error: err } = await client.rpc("owner_request_create", { p_location: cat.scope === "unit" ? "my_unit" : $("orWhere").value, p_unit: cat.scope === "unit" ? $("orUnit").value : null,
        p_category: cat.code, p_subject: $("orSubject").value, p_description: $("orDesc").value, p_urgency: $("orUrg").value, p_safety: $("orSafety").checked, p_inspector: $("orInsp").checked, p_photos: paths });
      if (err) throw new Error(await errorText(err));
      client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});   // emails the office (and the board when urgent) right away
      await mountOwnerRequests(el);
      const m = el.querySelector("#orMsg"); if (m) { m.className = "or-msg ok"; m.textContent = `Request #${data.number} received. We'll update it here.`; }
    } catch (e) { msg(e.message, "err"); btn.disabled = false; }
  };
  el.onclick = async (e) => {
    const c = e.target.closest("[data-cmt]"), w = e.target.closest("[data-wd]"), id = (c || w || {}).dataset && ((c || w).dataset.cmt || (c || w).dataset.wd);
    if (!id) return;
    const m = el.querySelector(`[data-rm="${id}"]`);
    try {
      let r;
      if (c) { const t = el.querySelector(`[data-note="${id}"]`).value; r = await client.rpc("owner_request_comment", { p_id: id, p_note: t }); }
      else { if (!confirm("Withdraw this request?")) return; r = await client.rpc("owner_request_withdraw", { p_id: id }); }
      if (r.error) throw new Error(await errorText(r.error));
      client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});   // emails the office right away
      await mountOwnerRequests(el);
    } catch (err) { m.className = "or-msg err"; m.textContent = err.message; }
  };
  el.querySelectorAll("img[data-ph]").forEach(async (img) => {
    const { data } = await client.storage.from("owner-requests").createSignedUrl(img.dataset.ph, 600);
    if (!data || !data.signedUrl) return;
    // HEIC photos don't display in most browsers: show an "Open photo" link instead of a broken image.
    img.onerror = () => { const a = document.createElement("a"); a.href = data.signedUrl; a.target = "_blank"; a.rel = "noopener"; a.textContent = "Open photo"; a.style.marginRight = "10px"; img.replaceWith(a); };
    img.src = data.signedUrl;
  });
}

// Photos live under the owner's id (the storage policy checks the first folder). The id comes back with the owner's own requests or from a tiny lookup.
async function ownerFolder() {
  const { data, error } = await client.rpc("owner_my_id");
  if (error || !data) throw new Error("Could not start the upload. Reload and try again.");
  return data;
}

function reqCard(r) {
  const open = !["done", "declined", "withdrawn"].includes(r.status), canWithdraw = ["new", "reviewing", "ranked"].includes(r.status);
  return `<div style="border-top:1px solid #eef1ec;padding:10px 0"><div><b>#${r.number} · ${esc(r.subject)}</b> <span class="or-pill ${esc(r.status)}">${esc(STATUS[r.status] || r.status)}</span>
    ${r.urgency === "urgent" || r.urgency === "emergency" ? `<span class="or-pill urgent">${esc(URG[r.urgency])}</span>` : ""}</div>
    <p class="or-sub">${esc(WHERE[r.location] || r.location)}${r.unit ? " · Unit " + esc(r.unit) : ""} · sent ${fmtDate(ctDate(r.created_at))}${r.priority_rank ? " · on the priority list as #" + esc(r.priority_rank) : ""}</p>
    <p style="margin:6px 0;white-space:pre-wrap">${esc(r.description)}</p>
    ${(r.photos || []).map((p) => `<img data-ph="${esc(p)}" alt="Photo" style="max-width:140px;max-height:140px;border-radius:8px;margin-right:6px">`).join("")}
    ${r.board ? `<div class="or-upd"><b>Board:</b> sent for a board decision (resolution ${esc(r.board.number || "draft")}, ${esc(r.board.status === "voting" ? "open for a vote" : r.board.status)}).</div>` : ""}
    ${r.response ? `<div class="or-upd"><b>Reply:</b> ${esc(r.response)}</div>` : ""}
    ${(r.updates || []).map((u) => `<div class="or-upd">${fmtDate(ctDate(u.at))} · ${u.by === "staff" ? "Office" : "You"}: ${esc(u.note)}</div>`).join("")}
    ${open ? `<div class="or-form"><label class="wide">Add a note (the office is emailed)<input data-note="${r.id}" maxlength="2000"></label><div class="wide"><button class="or-btn" type="button" data-cmt="${r.id}">Send note</button>${canWithdraw ? ` <button class="or-link" type="button" data-wd="${r.id}">Withdraw request</button>` : ""}</div></div>` : ""}
    <div class="or-msg" data-rm="${r.id}"></div></div>`;
}
