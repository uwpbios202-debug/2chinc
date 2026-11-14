// "Someone is parked in my stall": the occupant taps their own stall on the parking map (stalls.js shows "🚨 Someone in my stall?" on it),
// this opens the form right under the map. Alert everyone who lives here, then after 60 seconds request a tow (resident and owner portals, #parking).
// Database: supabase/migrations/20261118150000_parking_alerts_tow.sql. Unit 6: John raises alerts for stall 6 from his owner portal.
// New file on purpose (shared portal scripts can be cached by browsers).
import { client, esc, errorText } from "/assets/portal/portal.js";

const CSS = `
.pa{background:#fff;border:2px solid #b3261e;border-radius:12px;padding:14px 16px;margin-bottom:14px}
.pa h2{margin:0 0 6px;font-size:1.15rem}.pa p{margin:6px 0}.pa .sub{color:#5b6573;font-size:.9rem}
.pa .big{display:block;width:100%;max-width:420px;padding:14px 16px;border-radius:12px;border:0;background:#b3261e;color:#fff;font:700 1.05rem system-ui,sans-serif;cursor:pointer;margin:6px 0}
.pa .big.tow{background:#1b2430}.pa .big:disabled{opacity:.45;cursor:not-allowed}
.pa .ghost{background:none;border:1px solid #5b6573;color:#1b2430;border-radius:999px;padding:6px 14px;cursor:pointer;margin:4px 6px 0 0}
.pa .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px;max-width:520px}
.pa label{display:flex;flex-direction:column;font-size:.85rem;color:#5b6573}.pa input{font:inherit;padding:8px;border:1px solid #9aa59a;border-radius:8px}
.pa .count{font:700 2.2rem ui-monospace,Consolas,monospace}.pa .err{color:#b3261e}.pa .ok{color:#2e7d1f;font-weight:700}`;

export async function mountParkAlert(el) {
  if (!el) return;
  if (!document.getElementById("pa-css")) { const s = document.createElement("style"); s.id = "pa-css"; s.textContent = CSS; document.head.appendChild(s); }
  let D = null, form = null, timer = null, skew = 0;
  const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
  const telHref = () => D.tow.phone ? "tel:" + D.tow.phone.replace(/[^0-9+]/g, "") + (D.tow.option ? "," + D.tow.option : "") : "";
  const callText = () => D.tow.phone ? `${esc(D.tow.phone)}${D.tow.option ? ", option " + esc(D.tow.option) : ""}` : "";

  async function load() {
    const { data, error } = await client.rpc("parking_alert_mine");
    if (error) { D = { stalls: [], alerts: [], tow: {} }; el.innerHTML = ""; return; }
    D = data; draw();
  }
  function draw(msg) {
    clearInterval(timer);
    const stalls = (D.stalls || []).filter((s) => s.stall && !s.blocked);
    if (!stalls.length) { el.innerHTML = ""; return; }
    const live = (D.alerts || []).filter((a) => a.status === "open" || a.status === "tow_requested");
    const recent = (D.alerts || []).filter((a) => !live.includes(a)).slice(0, 3);
    let html = "";
    if (live.length) html = live.map(alertCard).join("");
    else if (form) html = formCard(form);
    else if (recent.length) html = `<p class="sub" style="margin:0 0 4px">Recent parking alerts: ${recent.map((a) => `stall ${esc(a.stall)}, ${new Date(a.alerted_at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}, ${esc(a.status.replace("_", " "))}`).join(" · ")}</p>`;
    el.innerHTML = html;
    wire(live);
  }
  const formCard = (f) => `<div class="pa"><h2>🚨 Vehicle in stall ${esc(f.stall)}</h2>
    <p class="sub">Describe the vehicle if you can (all optional), then send. If it is not moved, you can request a tow ${D.tow.wait || 60} seconds after the alert. Everyone who lives here and the office get the alert now. After you send, add photos of the vehicle.</p>
    <div class="grid"><label>Color, make, model<input id="paVeh" maxlength="80" placeholder="Silver Nissan Altima"></label>
      <label>License plate<input id="paPlate" maxlength="10" autocapitalize="characters"></label>
      <label>State<input id="paState" maxlength="2" placeholder="WI" autocapitalize="characters"></label></div>
    <label style="max-width:520px;margin-top:8px">Anything else (optional)<input id="paNote" maxlength="300"></label>
    <button class="big" type="button" id="paSend">Send alert to everyone</button><button class="ghost" type="button" id="paBack">Cancel</button>
    <p class="err" id="paMsg" role="status"></p></div>`;
  // Photos (ROCA1 Parking #18): front, back with the plate, the VIN through the windshield. Shown to the office and the tow company.
  const photoBox = (a) => `<div style="margin:8px 0"><label class="ghost" style="display:inline-block">📷 Add photos<input type="file" accept="image/*" capture="environment" multiple hidden data-pa-photo="${esc(a.id)}"></label>
    <span class="sub">${a.photo_count ? a.photo_count + " added. " : ""}Front, back with the plate, and the VIN through the windshield. The tow company sees them.</span>
    <span class="sub" data-pa-pmsg="${esc(a.id)}"></span></div>`;
  async function shrink(file, max = 1600) {
    try { const bmp = await createImageBitmap(file), k = Math.min(1, max / Math.max(bmp.width, bmp.height)), c = document.createElement("canvas");
      c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k); c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
      return await new Promise((res) => c.toBlob(res, "image/jpeg", 0.82)); } catch { return file; }
  }
  function alertCard(a) {
    if (a.status === "tow_requested") return `<div class="pa"><h2>🚛 Tow requested: stall ${esc(a.stall)}</h2>
      <p>${esc(D.tow.company || "The tow company")} and the office have the details by email.${D.tow.phone ? ` <b>Call dispatch now</b> so the truck comes: <b>${callText()}</b>.` : ""}</p>
      ${D.tow.phone ? `<a class="big tow" style="text-align:center;text-decoration:none" href="${telHref()}">📞 Call ${esc(D.tow.company || "dispatch")}</a>` : ""}
      ${photoBox(a)}<p class="sub">Do not touch or block the vehicle. Once it is gone, tap below.</p>
      <button class="ghost" type="button" data-pa-close="${esc(a.id)}" data-moved="1">It's gone. Close this alert</button></div>`;
    return `<div class="pa"><h2>🚨 Alert sent: stall ${esc(a.stall)}</h2>
      <p>${a.recipients} resident${a.recipients === 1 ? "" : "s"} and the office were emailed at ${new Date(a.alerted_at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}.</p>
      <p class="sub">The tow button turns on in:</p><div class="count" data-pa-count="${esc(a.id)}"></div>
      ${photoBox(a)}<button class="big tow" type="button" data-pa-tow="${esc(a.id)}" disabled>🚛 Request a tow</button>
      <button class="ghost" type="button" data-pa-close="${esc(a.id)}" data-moved="1">The vehicle moved</button><button class="ghost" type="button" data-pa-close="${esc(a.id)}">Cancel: my mistake</button>
      <p class="err" data-pa-msg="${esc(a.id)}" role="status"></p></div>`;
  }
  function wire(live) {
    const q = (s) => el.querySelector(s);
    if (q("#paBack")) q("#paBack").onclick = () => { form = null; draw(); };
    if (q("#paSend")) q("#paSend").onclick = async () => {
      q("#paSend").disabled = true; q("#paMsg").textContent = "";
      const { error } = await client.rpc("parking_alert_create", { p_unit: form.unit, p_vehicle: q("#paVeh").value, p_plate: q("#paPlate").value, p_plate_state: q("#paState").value, p_note: q("#paNote").value });
      if (error) { q("#paMsg").textContent = await errorText(error); q("#paSend").disabled = false; return; }
      form = null; flush(); load();
    };
    el.querySelectorAll("[data-pa-photo]").forEach((inp) => inp.onchange = async () => {
      const id = inp.dataset.paPhoto, m = el.querySelector(`[data-pa-pmsg="${id}"]`), files = [...inp.files].slice(0, 6), paths = [];
      if (!files.length) return; m.textContent = "Uploading…";
      try {
        for (const f of files) {
          const path = `${id}/${crypto.randomUUID()}.jpg`, blob = await shrink(f);
          const up = await client.storage.from("parking-alerts").upload(path, blob, { contentType: "image/jpeg" });
          if (up.error) throw new Error("A photo didn't upload. Try again.");
          paths.push(path);
        }
        const { error } = await client.rpc("parking_alert_add_photos", { p_id: id, p_paths: paths });
        if (error) throw new Error(await errorText(error));
        load();
      } catch (e) { m.textContent = e.message; }
    });
    el.querySelectorAll("[data-pa-close]").forEach((b) => b.onclick = async () => {
      const { error } = await client.rpc("parking_alert_close", { p_id: b.dataset.paClose, p_moved: !!b.dataset.moved });
      if (error) return; load();
    });
    el.querySelectorAll("[data-pa-tow]").forEach((b) => b.onclick = async () => {
      b.disabled = true;
      const m = el.querySelector(`[data-pa-msg="${b.dataset.paTow}"]`);
      const { error } = await client.rpc("parking_alert_tow", { p_id: b.dataset.paTow });
      if (error) { m.textContent = await errorText(error); b.disabled = false; return; }
      flush();
      if (D.tow.phone) location.href = telHref();   // the phone offers to call dispatch
      load();
    });
    const open = live.filter((a) => a.status === "open");
    if (!open.length) return;
    skew = new Date(open[0].now).getTime() - Date.now();   // server clock decides the wait
    let gone = 0;   // the map moves this box when it redraws; stop only once it has really left the page
    const tick = () => (!el.isConnected ? (++gone > 20 && clearInterval(timer)) : (gone = 0, open.forEach((a) => {
      const left = Math.max(0, Math.ceil((new Date(a.tow_unlock_at).getTime() - (Date.now() + skew)) / 1000));
      const c = el.querySelector(`[data-pa-count="${a.id}"]`), b = el.querySelector(`[data-pa-tow="${a.id}"]`);
      if (c) c.textContent = left ? left + "s" : "Ready";
      if (b) b.disabled = left > 0;
    })));
    tick(); timer = setInterval(tick, 500);
  }
  await load();
  // For the map: which stall labels the signed-in person may alert from (today), and opening the form for one.
  return {
    labels: () => (D.stalls || []).filter((s) => s.stall && !s.blocked).map((s) => s.stall),
    openFor(label) {
      const s = (D.stalls || []).find((x) => x.stall === label && !x.blocked);
      if (!s) return;
      const live = (D.alerts || []).some((a) => a.stall === label && (a.status === "open" || a.status === "tow_requested"));
      if (!live) { form = { unit: s.unit, stall: s.stall }; draw(); }
      el.scrollIntoView({ behavior: "smooth", block: "start" });
      const v = el.querySelector("#paVeh"); if (v) v.focus({ preventScroll: true });
    },
  };
}
