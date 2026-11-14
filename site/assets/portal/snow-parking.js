// The snow plow and the parking lot (Stephen, 11/8/2026), on https://2ndchinc.org/contractor/ for the snow vendor only:
//   1. The parking lot map (stalls, registered vehicles and photos, switches, guest holds), read-only.
//   2. "Vehicle not moved": the plow reports a vehicle left in a stall during snow removal, with photos. This at once requests a tow from
//      Always Towing (the request and photos show on Always Towing's page) and opens a $105 violation for the unit (office sends the notice).
// Database: supabase/migrations/20261118560000_snow_plow_parking.sql (snow_is_vendor, snow_not_moved, snow_not_moved_today).
import { client, esc, errorText } from "/assets/portal/portal.js";
import { mountStalls } from "/assets/portal/stalls.js?v=20261103b";

const CSS = `.sp{display:grid;gap:14px;margin:14px 0}.sp .panel h2{margin-top:0}
.sp .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:10px 0}
.sp label{display:grid;gap:3px;font-size:.85rem}.sp label.wide{grid-column:1/-1}
.sp input,.sp select{font:inherit;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg)}
.sp .warn{border-left:5px solid #b3261e;background:rgba(179,38,30,.07);padding:10px 14px;border-radius:6px}
.sp .big{font-size:1.05rem;padding:12px 18px}.sp .msg.err{color:#b3261e}.sp .msg.ok{color:#2e7d1f}
.sp .rep{border:1px solid var(--line);border-radius:10px;padding:10px 12px;display:grid;gap:4px}`;

async function shrink(file, max = 1600) {
  try { const bmp = await createImageBitmap(file), k = Math.min(1, max / Math.max(bmp.width, bmp.height)), c = document.createElement("canvas");
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k); c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
    return await new Promise((res) => c.toBlob(res, "image/jpeg", 0.82)); } catch { return file; }
}
async function addPhotos(alertId, files) {
  const paths = [];
  for (const f of [...files].slice(0, 6)) {
    const path = `${alertId}/${crypto.randomUUID()}.jpg`;
    const up = await client.storage.from("parking-alerts").upload(path, await shrink(f), { contentType: "image/jpeg" });
    if (up.error) throw new Error("A photo didn't upload. Try again.");
    paths.push(path);
  }
  if (paths.length) { const { error } = await client.rpc("parking_alert_add_photos", { p_id: alertId, p_paths: paths }); if (error) throw new Error(await errorText(error)); }
}

export async function mountSnowParking(el) {
  const { data: ok } = await client.rpc("snow_is_vendor");
  if (!ok) { el.hidden = true; return; }
  if (!document.getElementById("sp-css")) { const s = document.createElement("style"); s.id = "sp-css"; s.textContent = CSS; document.head.appendChild(s); }
  el.hidden = false;
  el.innerHTML = `<div class="sp">
    <div class="panel"><h2>Vehicle not moved for snow removal</h2>
      <p class="warn"><b>Reporting a vehicle does two things at once:</b> it asks Always Towing to tow it, and it opens a $105 fine for the unit. Use it only for a vehicle left in the lot during snow removal, after the residents were emailed.</p>
      <div class="grid"><label>Stall<select id="spStall"><option value="">Loading…</option></select></label>
        <label>Plate<input id="spPlate" maxlength="10" autocapitalize="characters"></label><label>State<input id="spState" maxlength="2" placeholder="WI" autocapitalize="characters"></label>
        <label>Vehicle<input id="spVeh" maxlength="80" placeholder="Silver Nissan Altima"></label>
        <label class="wide">Note (optional)<input id="spNote" maxlength="300" placeholder="Blocking the north side of the lot"></label>
        <label class="wide">Photos: front, back with the plate, and the stall (at least one)<input id="spPhotos" type="file" accept="image/*" capture="environment" multiple></label></div>
      <button class="btn primary big" type="button" id="spSend">Report: request tow + $105 fine</button> <span class="msg" id="spMsg"></span>
      <div id="spToday"></div></div>
    <div id="spLot"></div></div>`;
  const $ = (id) => el.querySelector("#" + id);
  mountStalls($("spLot"));
  const { data: lot } = await client.rpc("parking_lot_mine", { p_date: new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" }) });
  $("spStall").innerHTML = `<option value="">Choose the stall</option>` + ((lot && lot.stalls) || []).map((s) => `<option value="${esc(s.label)}">${esc(s.label)}${s.kind === "unit" ? "" : " (" + esc(s.kind) + ")"}</option>`).join("");

  async function today() {
    const { data } = await client.rpc("snow_not_moved_today");
    $("spToday").innerHTML = (data || []).length ? `<h3 style="margin:14px 0 6px">Reported today</h3>` + data.map((r) => `<div class="rep"><b>Stall ${esc(r.stall)}</b>
        <span>${esc([r.vehicle, r.plate].filter(Boolean).join(", ") || "vehicle")} · ${esc(r.status === "tow_requested" ? "tow requested" : r.status)} · ${r.photos} photo${r.photos === 1 ? "" : "s"}</span>
        <label>Add photos<input type="file" accept="image/*" capture="environment" multiple data-more="${esc(r.id)}"></label></div>`).join("") : "";
    el.querySelectorAll("[data-more]").forEach((i) => i.onchange = async () => {
      try { await addPhotos(i.dataset.more, i.files); await today(); } catch (e) { $("spMsg").className = "msg err"; $("spMsg").textContent = e.message; }
    });
  }
  await today();

  $("spSend").onclick = async () => {
    const m = $("spMsg"), b = $("spSend"), files = $("spPhotos").files, stall = $("spStall").value;
    m.className = "msg";
    if (!stall) { m.textContent = "Choose the stall."; return; }
    if (!files.length) { m.textContent = "Add at least one photo."; return; }
    if (!confirm(`Stall ${stall}: request a tow from Always Towing AND open a $105 fine for the unit?`)) return;
    b.disabled = true; m.textContent = "Sending…";
    try {
      const { data: r, error } = await client.rpc("snow_not_moved", { p_stall: stall, p_plate: $("spPlate").value, p_plate_state: $("spState").value, p_vehicle: $("spVeh").value, p_note: $("spNote").value });
      if (error) throw new Error(await errorText(error));
      await addPhotos(r.alert_id, files);
      client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
      ["spPlate", "spState", "spVeh", "spNote", "spPhotos"].forEach((id) => $(id).value = ""); $("spStall").value = "";
      m.className = "msg ok"; m.textContent = `Sent. Always Towing and the office have it; the fine was opened for Unit ${r.fine_unit}.`;
      await today();
    } catch (e) { m.className = "msg err"; m.textContent = e.message; }
    b.disabled = false;
  };
}
