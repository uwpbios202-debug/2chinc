// VIN box for "Register my vehicle" / "I have a loaner": type it or say it (🎤), then Look up fills year, make and model from NHTSA's free
// vPIC decoder (https://vpic.nhtsa.dot.gov, no key, called from the browser). The tenant checks the result and can change anything.
// Optional: older (pre-1981) or some imported vehicles do not decode; then they type the details as before.

const CSS = `.vin{grid-column:1/-1;background:#f3f7f1;border:1px solid #d9dfd6;border-radius:10px;padding:10px 12px}
.vin .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:4px}
.vin input{font:600 1.05rem ui-monospace,Consolas,monospace;letter-spacing:.08em;text-transform:uppercase;flex:1;min-width:200px;padding:8px 10px;border:1px solid #9aa59a;border-radius:8px}
.vin button{border-radius:999px;padding:8px 14px;font-weight:700;cursor:pointer;border:1px solid #2e7d1f;background:#fff;color:#2e7d1f}
.vin button.look{background:#2e7d1f;color:#fff}.vin button.rec{background:#b3261e;color:#fff;border-color:#b3261e}
.vin .msg{font-size:.9rem;margin-top:6px}.vin .ok{color:#2e7d1f}.vin .err{color:#b3261e}.vin .sub{color:#5b6573;font-size:.85rem}`;

const SR = window.SpeechRecognition || window.webkitSpeechRecognition;

export function vinFieldHtml() {
  if (!document.getElementById("vin-css")) { const s = document.createElement("style"); s.id = "vin-css"; s.textContent = CSS; document.head.appendChild(s); }
  return `<div class="vin"><b>VIN</b> <span class="sub">(optional: fills in the year, make and model for you)</span>
    <div class="row"><input id="pkVin" maxlength="24" autocomplete="off" autocapitalize="characters" spellcheck="false" inputmode="text" placeholder="17 letters and numbers" aria-label="VIN">
      ${SR ? `<button type="button" id="pkVinMic" aria-label="Say the VIN">🎤 Say it</button>` : ""}<button type="button" class="look" id="pkVinLook">Look up</button></div>
    <div class="sub">Find it through the windshield on the driver's side of the dashboard, on the sticker in the driver's door frame, or on your registration or insurance card.${SR ? " Tap Say it and read it out slowly, letter by letter." : " Tip: the microphone on your phone's keyboard can type it for you."}</div>
    <div class="msg" id="pkVinMsg" role="status"></div></div>`;
}

// Spoken words to VIN characters: "one two bee", "B as in boy", "alpha", "oh" (a VIN has no O, so it is zero).
const WORDS = { zero: "0", oh: "0", o: "0", one: "1", won: "1", two: "2", to: "2", too: "2", three: "3", four: "4", for: "4", fore: "4", five: "5", six: "6", seven: "7", eight: "8", ate: "8", nine: "9",
  ay: "A", a: "A", bee: "B", be: "B", see: "C", sea: "C", cee: "C", dee: "D", e: "E", ee: "E", ef: "F", eff: "F", gee: "G", aitch: "H", h: "H", jay: "J", kay: "K", k: "K", el: "L", ell: "L", em: "M", en: "N",
  pee: "P", pea: "P", are: "R", ar: "R", ess: "S", es: "S", tee: "T", tea: "T", you: "U", u: "U", vee: "V", ex: "X", why: "Y", zee: "Z", zed: "Z", i: "1", eye: "1", queue: "0", q: "0" };
const NATO = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "juliet", "kilo", "lima", "mike", "november", "papa", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu"];
export function spokenToVin(text) {
  let t = String(text || "").toLowerCase().replace(/double\s+(u|you)/g, " w ").replace(/x-ray/g, "xray").replace(/\b([a-z])\s+(as in|like|for)\s+\w+/g, " $1 ");
  return t.split(/[\s,.\-]+/).filter(Boolean).map((w) => {
    if (/^[0-9]+$/.test(w)) return w;
    if (WORDS[w] !== undefined) return WORDS[w];
    if (NATO.includes(w)) return w[0].toUpperCase();
    if (/^[a-z0-9]+$/.test(w) && w.length <= 3 && !WORDS[w]) return w.toUpperCase();   // "4t1" said as a group
    return "";
  }).join("").toUpperCase().replace(/[IOQ]/g, (c) => (c === "I" ? "1" : "0"));
}

export function cleanVin(v) { return String(v || "").toUpperCase().replace(/[^A-Z0-9]/g, "").replace(/[OQ]/g, "0").replace(/I/g, "1"); }
// 9th character check digit (required for North American vehicles: VINs starting 1-5).
export function vinCheckOk(v) {
  const val = (c) => /[0-9]/.test(c) ? Number(c) : "A1B2C3D4E5F6G7H8J1K2L3M4N5P7R9S2T3U4V5W6X7Y8Z9".split("").reduce((m, ch, i, a) => (i % 2 === 0 ? (m[ch] = Number(a[i + 1]), m) : m), {})[c];
  const w = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
  const sum = v.split("").reduce((s, c, i) => s + (val(c) || 0) * w[i], 0), r = sum % 11;
  return (r === 10 ? "X" : String(r)) === v[8];
}

export function wireVin(root, { onFound } = {}) {
  const $ = (id) => root.querySelector("#" + id);
  const inp = $("pkVin"); if (!inp) return;
  const msg = (t, cls) => { $("pkVinMsg").className = "msg " + (cls || ""); $("pkVinMsg").textContent = t; };
  inp.addEventListener("input", () => { const c = cleanVin(inp.value); if (c !== inp.value) inp.value = c; });
  if ($("pkVinMic")) $("pkVinMic").onclick = () => {
    const b = $("pkVinMic"), r = new SR();
    r.lang = "en-US"; r.interimResults = false; r.maxAlternatives = 1; r.continuous = false;
    b.classList.add("rec"); b.textContent = "● Listening…"; msg("Read the VIN out slowly, letter by letter.");
    r.onresult = (e) => { const said = e.results[0][0].transcript, v = spokenToVin(said); inp.value = cleanVin((inp.value || "") + v); msg(`Heard: "${said}". Check the VIN in the box, fix anything, then tap Look up.`); };
    r.onerror = (e) => msg(e.error === "not-allowed" ? "The microphone is blocked for this site. Allow it in your browser settings, or type the VIN." : "Didn't catch that. Try again, or type it.", "err");
    r.onend = () => { b.classList.remove("rec"); b.textContent = "🎤 Say it"; };
    try { r.start(); } catch (e) { r.onend(); }
  };
  $("pkVinLook").onclick = async () => {
    const v = cleanVin(inp.value); inp.value = v;
    if (v.length !== 17) return msg(`A VIN has 17 letters and numbers; this has ${v.length}. Check it and try again.`, "err");
    if (/^[1-5]/.test(v) && !vinCheckOk(v)) return msg("This VIN doesn't add up: one character is probably wrong. Compare it with the sticker and try again.", "err");
    msg("Looking up…");
    try {
      const res = await fetch(`https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/${encodeURIComponent(v)}?format=json`);
      const r = ((await res.json()).Results || [])[0] || {};
      if (!r.Make) return msg("We couldn't find this VIN. Check it, or just fill in the year, make and model below.", "err");
      const make = r.Make.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());
      const found = { year: r.ModelYear || "", make, model: r.Model || "", trim: r.Trim || "", body: r.BodyClass || "" };
      onFound && onFound(found);
      msg(`Found: ${[found.year, found.make, found.model, found.trim].filter(Boolean).join(" ")}${found.body ? " (" + found.body.toLowerCase() + ")" : ""}. Is this your vehicle? We filled it in below; change anything that's wrong, then add the color, plate and photos.`, "ok");
    } catch (e) { msg("The VIN lookup isn't answering right now. Please fill in the year, make and model below.", "err"); }
  };
}
