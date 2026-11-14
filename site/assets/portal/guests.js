// Guest requests for tenants and owners (resident portal #guests, owner portal #guests).
// One form for an overnight stay, guest parking, or both. The office approves every request and, for parking,
// hands over a physical decal. Overnight guests are limited by the lease to 13 nights in 12 months without the
// landlord's written consent. Database: supabase/migrations/20261105210000_guest_requests.sql.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

const CSS = `
.gq{display:grid;gap:14px}.gq-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.gq h2{margin:0 0 6px;font-size:1.2rem}.gq-sub{color:#5b6573;font-size:.88rem;margin:0}
.gq-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-top:10px}
.gq-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}.gq-form .wide{grid-column:1/-1}
.gq-form input,.gq-form select,.gq-form textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.gq-checks{display:flex;gap:16px;flex-wrap:wrap}.gq-checks label{display:flex;gap:6px;align-items:center;color:#1b2430;font-size:.95rem}
.gq-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:10px 20px;font-weight:700;cursor:pointer}.gq-btn:disabled{opacity:.5}
.gq-link{background:none;border:0;color:#2e7d1f;font-weight:600;cursor:pointer;padding:0;text-decoration:underline}
.gq-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.gq-pill.pending{background:#fff3cd;color:#7a5200}.gq-pill.declined,.gq-pill.cancelled{background:#eee;color:#555}
.gq-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.gq-msg.err{color:#b3261e}.gq-msg.ok{color:#2e7d1f}
.gq-warn{background:#fff3cd;border-radius:8px;padding:8px 10px;font-size:.88rem;color:#5c3d00}`;

const WHAT = (r) => r.overnight && r.parking ? "Overnight stay + parking" : r.overnight ? "Overnight stay" : "Guest parking";
const STATUS = (r) => r.status === "approved" && r.parking && !r.decal_given_at ? "approved: pick up the decal" : r.status === "approved" && r.decal_given_at ? "approved: decal " + (r.decal_number || "given") : r.status;

export async function mountGuests(el) {
  if (!document.getElementById("gq-css")) { const s = document.createElement("style"); s.id = "gq-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.innerHTML = `<p class="gq-sub">Loading…</p>`;
  const { data, error } = await client.rpc("guest_requests_mine");
  if (error) { el.innerHTML = `<p class="gq-msg err">${esc(await errorText(error))}</p>`; return; }
  const units = data.units || [], reqs = data.requests || [], today = new Date().toISOString().slice(0, 10);
  if (!units.length) { el.innerHTML = `<p class="gq-sub">Guest requests are for current tenants and owners.</p>`; return; }
  el.innerHTML = `<div class="gq">
    <div class="gq-card"><h2>Ask for a guest</h2>
      <p class="gq-sub">For an overnight guest, guest parking, or both. The office approves every request. For parking, pick up the guest decal from the office${data.office_phone ? " (" + esc(data.office_phone) + ")" : ""} and display it in the guest's vehicle. The lease allows a guest up to 13 nights in any 12 months; longer stays need our written approval.</p>
      <form class="gq-form" id="gqForm" novalidate>
        ${units.length > 1 ? `<label>Unit<select id="gqUnit">${units.map((u) => `<option value="${esc(u.unit)}">Unit ${esc(u.unit)}${u.kind === "owner" ? " (owner)" : ""}</option>`).join("")}</select></label>` : ""}
        <label>Guest's full name<input id="gqName" autocomplete="off" required></label>
        <label>Guest's phone (optional)<input id="gqPhone" type="tel" inputmode="tel"></label>
        <div class="wide gq-checks"><label><input type="checkbox" id="gqNight"> Overnight stay</label><label><input type="checkbox" id="gqPark"> Guest parking</label></div>
        <label>Arriving<input id="gqStart" type="date" min="${today}" required></label>
        <label>Leaving<input id="gqEnd" type="date" min="${today}" required></label>
        <div class="wide" id="gqCar" hidden><div class="gq-form" style="margin:0">
          <label>Vehicle make<input id="gqMake" placeholder="Ford"></label><label>Model<input id="gqModel" placeholder="Focus"></label>
          <label>Color<input id="gqColor"></label><label>License plate<input id="gqPlate" style="text-transform:uppercase"></label>
          <label>Plate state<input id="gqState" maxlength="2" placeholder="WI" style="text-transform:uppercase"></label></div></div>
        <label class="wide">Anything we should know? (optional)<textarea id="gqNote" rows="2" maxlength="500"></textarea></label>
        <div class="wide"><button class="gq-btn" type="submit" id="gqSend">Send request</button><div class="gq-msg" id="gqMsg" role="status"></div></div>
      </form></div>
    <div class="gq-card"><h2>Your requests</h2>
      ${reqs.length ? reqs.map((r) => `<div style="border-top:1px solid #eef1ec;padding:10px 0">
        <div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap"><b>${esc(r.guest_name)} · Unit ${esc(r.unit_number)}</b><span class="gq-pill ${esc(r.status)}">${esc(STATUS(r))}</span></div>
        <div class="gq-sub">${WHAT(r)} · ${fmtDate(r.start_date)} to ${fmtDate(r.end_date)}${r.overnight ? ` · ${r.nights} night${r.nights === 1 ? "" : "s"}` : ""}${r.parking && r.plate ? ` · plate ${esc(r.plate)}` : ""}</div>
        ${r.overnight && r.nights_12mo != null ? `<div class="gq-sub">This guest's overnight nights in the last 12 months, counting this request: ${r.nights_12mo} of 13${r.over_limit_consent ? " (approved beyond 13 with our written consent)" : ""}</div>` : ""}
        ${(r.status === "pending" || r.status === "approved") && !r.decal_given_at && r.end_date >= today ? `<button class="gq-link" type="button" data-gqcancel="${esc(r.id)}">Cancel this request</button>` : ""}
      </div>`).join("") : `<p class="gq-sub">No guest requests yet.</p>`}
    </div></div>`;

  const $ = (id) => el.querySelector("#" + id), v = (id) => ($(id) ? $(id).value.trim() : "");
  const say = (t, bad) => { $("gqMsg").className = "gq-msg " + (bad ? "err" : "ok"); $("gqMsg").textContent = t; };
  $("gqPark").onchange = () => { $("gqCar").hidden = !$("gqPark").checked; };
  $("gqStart").onchange = () => { $("gqEnd").min = v("gqStart") || today; if (!v("gqEnd") || v("gqEnd") < v("gqStart")) $("gqEnd").value = v("gqStart"); };
  $("gqForm").onsubmit = async (e) => {
    e.preventDefault();
    if (!$("gqNight").checked && !$("gqPark").checked) return say("Choose overnight stay, guest parking, or both.", true);
    $("gqSend").disabled = true; say("Sending…");
    const { error: err } = await client.rpc("guest_request_create", {
      p_unit: units.length > 1 ? v("gqUnit") : units[0].unit, p_guest: v("gqName"), p_guest_phone: v("gqPhone"),
      p_overnight: $("gqNight").checked, p_parking: $("gqPark").checked, p_start: v("gqStart") || null, p_end: v("gqEnd") || null,
      p_make: v("gqMake"), p_model: v("gqModel"), p_color: v("gqColor"), p_plate: v("gqPlate"), p_plate_state: v("gqState"), p_note: v("gqNote"),
    });
    if (err) { $("gqSend").disabled = false; return say(await errorText(err), true); }
    client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});   // tells the office right away
    await mountGuests(el);
    el.querySelector("#gqMsg").className = "gq-msg ok"; el.querySelector("#gqMsg").textContent = "Sent. We'll email you when the office decides.";
  };
  el.querySelectorAll("[data-gqcancel]").forEach((b) => b.onclick = async () => {
    if (!confirm("Cancel this guest request?")) return;
    const { error: err } = await client.rpc("guest_request_cancel", { p_id: b.dataset.gqcancel });
    if (err) return alert(await errorText(err));
    mountGuests(el);
  });
}
