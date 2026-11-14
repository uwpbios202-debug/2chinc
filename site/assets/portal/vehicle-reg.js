// Register the vehicle that parks in a unit's stall (Stephen, 11/8/2026), for people who are not tenants on a lease:
// owners who live in their unit (1, 7, 13), owners of a unit with no active lease (15, 17), and the parking-and-keys person of an
// owner-managed unit (Unit 6, on https://2ndchinc.org/unit-access/). Tenants keep the form in the resident portal.
// Database: vehicle_reg_* in supabase/migrations/20261118400000_parking_registration_tow_link.sql.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";
import { vinFieldHtml, wireVin, cleanVin } from "/assets/portal/vin.js";

const CSS = `.vr .pkopts{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin:10px 0}
.vr .pkopts button{text-align:left;background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:10px;padding:12px 14px;cursor:pointer;font:inherit}
.vr .pkopts button:hover,.vr .pkopts button.on{border-color:#2e7d1f;background:rgba(46,125,31,.08)}
.vr .pkopts button:disabled{opacity:.5;cursor:default}.vr .pkopts b{display:block}
.vr .vcard{border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:grid;gap:4px}
.vr .vgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px;margin-top:8px}
.vr .vph{display:grid;grid-template-columns:1fr 1fr;gap:6px}.vr .vph img{width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:8px;background:#e8ece6}
.vr .pkform{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-top:10px}
.vr .pkform label{display:grid;gap:3px;font-size:.85rem}.vr .pkform label.wide{grid-column:1/-1}
.vr .pkform input:not([type=checkbox]){font:inherit;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--fg);width:100%;box-sizing:border-box}
.vr .due{border-left:4px solid #b3261e;padding:8px 12px;background:rgba(179,38,30,.07);border-radius:6px}
.vr .msg2{font-size:.92rem;margin-top:6px}.vr .msg2.err{color:#b3261e}.vr .msg2.ok{color:#2e7d1f}`;
const KIND = { own: "Vehicle", loaner: "Loaner", visitor: "Regular visitor" };

async function shrinkPhoto(file, max = 1600) {
  try {
    const bmp = await createImageBitmap(file), s = Math.min(1, max / Math.max(bmp.width, bmp.height));
    const c = document.createElement("canvas"); c.width = Math.round(bmp.width * s); c.height = Math.round(bmp.height * s);
    c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
    return await new Promise((r) => c.toBlob(r, "image/jpeg", 0.82));
  } catch { return file; }
}

export async function mountVehicleReg(el) {
  if (!document.getElementById("vr-css")) { const s = document.createElement("style"); s.id = "vr-css"; s.textContent = CSS; document.head.appendChild(s); }
  const st = { data: null, unit: "", mode: "" };
  const $ = (id) => el.querySelector("#" + id);
  const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});

  async function load() {
    const { data, error } = await client.rpc("vehicle_reg_mine");
    if (error) { el.innerHTML = `<p class="sub">${esc(await errorText(error))}</p>`; return; }
    st.data = data;
    if (!data.units.length) { el.innerHTML = ""; return; }
    if (!data.units.some((u) => u.unit === st.unit)) st.unit = data.units[0].unit;
    draw();
  }

  function draw() {
    const D = st.data, U = D.units.find((u) => u.unit === st.unit), vs = U.vehicles, dec = U.declaration;
    const hasOwn = vs.some((v) => v.kind === "own"), hasLoan = vs.some((v) => v.kind === "loaner"), answered = vs.length || (dec && dec.no_vehicle);
    const opt = (k, t, d, off) => `<button type="button" data-m="${k}" class="${st.mode === k ? "on" : ""}" ${off ? "disabled" : ""}><b>${t}</b><span class="sub">${d}</span></button>`;
    const f = (id, label, attrs = "", wide = false) => `<label class="${wide ? "wide" : ""}">${label}<input id="${id}" ${attrs}></label>`;
    const ph = (id, label) => `<label>${label}<input id="${id}" type="file" accept="image/*" capture="environment"></label>`;
    let form = "";
    if (st.mode === "own" || st.mode === "loaner") {
      form = `<div class="pkform">${vinFieldHtml()}${f("pkMake", "Make", 'maxlength="40" placeholder="Toyota"')}${f("pkModel", "Model", 'maxlength="40" placeholder="Camry"')}${f("pkColor", "Color", 'maxlength="30"')}${f("pkYear", "Year", 'type="number" min="1950" max="2100"')}
        ${f("pkPlate", "License plate", 'maxlength="12"')}${f("pkState", "Plate state", 'maxlength="2" placeholder="WI"')}
        ${st.mode === "loaner" ? f("pkWhy", "Why do you have a loaner?", 'maxlength="200" placeholder="My car is in the repair shop"', true) + f("pkLender", "Who lent it (shop or person)", 'maxlength="100"') + f("pkFrom", "Since", 'type="date"') + f("pkUntil", "Return it by", 'type="date"') : ""}
        ${ph("pkFront", "Photo of the FRONT")}${ph("pkBack", "Photo of the BACK")}</div>
        <p class="sub">Take both photos so the whole vehicle and its plate can be seen.</p>`;
    } else if (st.mode === "visitor") {
      form = `<div class="pkform">${f("pkVName", "Visitor's name", 'maxlength="80"')}${f("pkVRel", "Who are they to you?", 'maxlength="40" placeholder="Friend, caregiver"')}${f("pkVFreq", "How often do they park here?", 'maxlength="80" placeholder="Every Sunday"')}
        ${f("pkPlate", "License plate (if you know it)", 'maxlength="12"')}${f("pkState", "Plate state", 'maxlength="2" placeholder="WI"')}${f("pkNote", "Anything else", 'maxlength="200"')}</div>`;
    } else if (st.mode === "none") {
      form = `<div class="pkform"><label class="wide"><span><input type="checkbox" id="pkVisitors"> A regular visitor parks in this stall</span></label>${f("pkNote", "Tell us about them (optional)", 'maxlength="200"', true)}</div>`;
    }
    const due = !answered && D.register_by ? `<p class="due"><b>Register by ${fmtDate(D.register_by)}.</b>${D.enforce_from ? ` From ${fmtDate(D.enforce_from)} Always Towing patrols the lot and may tow any vehicle in a numbered stall that is not registered to that unit.` : ""}</p>` : "";
    el.innerHTML = `<div class="vr"><h2>Register the vehicle for stall ${esc(U.unit)}</h2>
      ${D.units.length > 1 ? `<div class="row" style="gap:6px;flex-wrap:wrap">${D.units.map((u) => `<button type="button" class="btn ${u.unit === st.unit ? "primary" : ""}" data-u="${esc(u.unit)}">Unit ${esc(u.unit)}</button>`).join("")}</div>` : ""}
      ${due}
      ${vs.length ? `<div class="vgrid">${vs.map((v) => `<div class="vcard"><b>${esc(KIND[v.kind] || v.kind)}</b>${v.kind === "loaner" && v.loaner_until ? `<span class="sub">until ${fmtDate(v.loaner_until)}</span>` : ""}
          <div>${v.kind === "visitor" ? esc((v.visitor_name || "Visitor") + " · " + (v.visitor_frequency || "")) : esc([v.color, v.year, v.make, v.model].filter(Boolean).join(" "))}</div>
          ${v.plate ? `<div class="sub">Plate ${esc(v.plate)} ${esc(v.plate_state || "")}</div>` : ""}
          ${v.front_path || v.back_path ? `<div class="vph"><img data-pk="${esc(v.front_path || "")}" alt="Front"><img data-pk="${esc(v.back_path || "")}" alt="Back"></div>` : ""}
          <div><button class="btn" type="button" data-end="${esc(v.id)}">Remove</button></div></div>`).join("")}</div>`
        : `<p class="sub">${dec && dec.no_vehicle ? "You told us no vehicle parks here" + (dec.has_regular_visitors ? ", except a regular visitor" : "") + "." : "Nothing registered yet."}</p>`}
      <div class="pkopts">${opt("own", "Register a vehicle", "Make, model, plate and front and back photos", hasOwn)}${opt("loaner", "A loaner", "A temporary vehicle, for example while yours is in the shop", hasLoan)}
        ${opt("none", "No vehicle", "No vehicle parks in this stall", false)}${opt("visitor", "A regular visitor parks here", "Name, how often, and their plate", false)}</div>
      ${form}${form ? `<div class="row" style="gap:8px;margin-top:10px"><button class="btn primary" type="button" id="pkSave">Save</button><button class="btn" type="button" id="pkCancel">Cancel</button></div>` : ""}
      <div class="msg2" id="pkMsg"></div></div>`;
    wire();
  }

  async function paint() {
    const imgs = [...el.querySelectorAll("img[data-pk]")].filter((i) => i.dataset.pk);
    if (!imgs.length) return;
    const { data } = await client.storage.from("vehicles").createSignedUrls(imgs.map((i) => i.dataset.pk), 3600);
    const by = Object.fromEntries((data || []).map((x) => [x.path, x.signedUrl]));
    imgs.forEach((i) => { if (by[i.dataset.pk]) i.src = by[i.dataset.pk]; });
  }

  function wire() {
    paint();
    const say = (t, bad) => { $("pkMsg").className = "msg2 " + (bad ? "err" : "ok"); $("pkMsg").textContent = t; };
    el.querySelectorAll("[data-u]").forEach((b) => b.onclick = () => { st.unit = b.dataset.u; st.mode = ""; draw(); });
    el.querySelectorAll("[data-m]").forEach((b) => b.onclick = () => { st.mode = b.dataset.m; draw(); });
    if ($("pkCancel")) $("pkCancel").onclick = () => { st.mode = ""; draw(); };
    if ($("pkVin")) wireVin(el, { onFound: (v) => { if (v.make) $("pkMake").value = v.make; if (v.model) $("pkModel").value = v.model; if (v.year) $("pkYear").value = v.year; } });
    el.querySelectorAll("[data-end]").forEach((b) => b.onclick = async () => {
      if (!confirm("Remove this vehicle from the stall?")) return;
      const { error } = await client.rpc("vehicle_reg_end", { p_id: b.dataset.end });
      if (error) return say(await errorText(error), true);
      flush(); load();
    });
    if ($("pkSave")) $("pkSave").onclick = async () => {
      const b = $("pkSave"), val = (id) => ($(id) ? $(id).value.trim() : ""), mode = st.mode, unit = st.unit;
      b.disabled = true; say("Saving…");
      try {
        if (mode === "none") {
          const { error } = await client.rpc("vehicle_reg_declare", { p_unit: unit, p_no_vehicle: true, p_visitors: $("pkVisitors").checked, p_note: val("pkNote") });
          if (error) throw new Error(await errorText(error));
        } else {
          const id = crypto.randomUUID(); let front = null, back = null;
          if (mode !== "visitor") {
            const ff = $("pkFront").files[0], bf = $("pkBack").files[0];
            if (!ff || !bf) throw new Error("Add a photo of the front and a photo of the back.");
            for (const [file, name] of [[ff, "front"], [bf, "back"]]) {
              const blob = await shrinkPhoto(file), path = `${unit}/${id}/${name}.jpg`;
              const up = await client.storage.from("vehicles").upload(path, blob, { contentType: "image/jpeg", upsert: true });
              if (up.error) throw new Error("A photo didn't upload. Check your connection and try again.");
              if (name === "front") front = path; else back = path;
            }
          }
          const { error } = await client.rpc("vehicle_reg_save", {
            p_unit: unit, p_id: id, p_kind: mode, p_make: val("pkMake"), p_model: val("pkModel"), p_color: val("pkColor"), p_year: val("pkYear") ? Number(val("pkYear")) : null,
            p_plate: val("pkPlate"), p_plate_state: val("pkState"), p_loaner_reason: val("pkWhy"), p_loaner_lender: val("pkLender"), p_loaner_from: val("pkFrom") || null, p_loaner_until: val("pkUntil") || null,
            p_visitor_name: val("pkVName"), p_visitor_relationship: val("pkVRel"), p_visitor_frequency: val("pkVFreq"), p_notes: val("pkNote"), p_front: front, p_back: back });
          if (error) throw new Error(await errorText(error));
          const vin = cleanVin(val("pkVin"));
          if (vin && mode !== "visitor") { const { error: verr } = await client.rpc("vehicle_reg_set_vin", { p_id: id, p_vin: vin }); if (verr) throw new Error("Saved, but the VIN wasn't: " + await errorText(verr)); }
        }
        flush(); st.mode = ""; await load();
      } catch (e) { say(e.message, true); b.disabled = false; }
    };
  }

  el.innerHTML = `<p class="sub">Loading…</p>`;
  await load();
}
