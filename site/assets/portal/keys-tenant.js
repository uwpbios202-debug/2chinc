// Tenants add their own unit entry door key code(s), one at a time, up to 3 (resident portal #keys). Unit 6 never (no tenant there).
// Database: supabase/migrations/20261118140000_tenant_unit_door_codes.sql (keys_tenant_status, keys_tenant_add_code).
// Each saved code emails info@2ndchinc.org (without the code). New file on purpose: keys.js is cached by browsers.
import { client, esc, errorText } from "/assets/portal/portal.js";

const CSS = `
.kya{background:#fff;border:2px solid #2e7d1f;border-radius:12px;padding:14px 16px;margin-bottom:14px}
.kya h2{margin:0 0 4px;font-size:1.15rem}.kya p{margin:4px 0}.kya .sub{color:#5b6573;font-size:.9rem}
.kya input{font:700 1.3rem ui-monospace,Consolas,monospace;letter-spacing:.1em;padding:8px 10px;border:1px solid #9aa59a;border-radius:8px;max-width:220px;width:100%}
.kya .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:8px}
.kya button{border-radius:999px;padding:8px 18px;font-weight:700;cursor:pointer;border:1px solid #2e7d1f}
.kya .yes{background:#2e7d1f;color:#fff}.kya .no{background:#fff;color:#2e7d1f}
.kya .err{color:#b3261e}.kya .ok{color:#2e7d1f;font-weight:700}`;

export async function mountKeyAdd(el, onAdded) {
  if (!el) return;
  if (!document.getElementById("kya-css")) { const s = document.createElement("style"); s.id = "kya-css"; s.textContent = CSS; document.head.appendChild(s); }
  const { data: st, error } = await client.rpc("keys_tenant_status");
  if (error || !st || !st.can_add) { el.innerHTML = ""; return; }
  let count = Number(st.count) || 0;
  const max = Number(st.max) || 3, unit = st.unit;

  const form = (lead) => {
    if (count >= max) { el.innerHTML = `<div class="kya"><p class="sub">Unit ${esc(unit)} has ${max} entry door codes on file. To change one, please contact the office.</p></div>`; return; }
    el.innerHTML = `<div class="kya">${lead || ""}<h2>${count ? "Add another code for your unit's entry door" : "Add your unit's entry door key code"}</h2>
      <p class="sub">Type the code stamped on the key to <b>your own unit's entry door</b> (Unit ${esc(unit)}). Not the glass entry door: that one is already on file.</p>
      <div class="row"><input id="kyaCode" maxlength="40" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="Key code" aria-label="Unit entry door key code">
      <button class="yes" type="button" id="kyaSave">Submit code</button></div><p class="err" id="kyaMsg" role="status"></p></div>`;
    el.querySelector("#kyaSave").onclick = save;
  };
  const ask = () => {
    if (count >= max) { form(`<p class="ok">Thank you. Your code was sent to the office.</p>`); return; }
    el.innerHTML = `<div class="kya"><p class="ok">Thank you. Your code was sent to the office.</p>
      <h2>Do you have another code for your unit's entry door?</h2><p class="sub">Most units have only one. Not the glass entry door.</p>
      <div class="row"><button class="yes" type="button" id="kyaYes">Yes, add another</button><button class="no" type="button" id="kyaNo">No, that's all</button></div></div>`;
    el.querySelector("#kyaYes").onclick = () => form();
    el.querySelector("#kyaNo").onclick = () => { el.innerHTML = `<div class="kya"><p class="ok">All set. Your unit's door code${count > 1 ? "s are" : " is"} on file below.</p></div>`; };
  };
  async function save() {
    const inp = el.querySelector("#kyaCode"), msg = el.querySelector("#kyaMsg"), btn = el.querySelector("#kyaSave");
    const code = inp.value.trim();
    if (!code) { msg.textContent = "Type the code on your key first."; inp.focus(); return; }
    btn.disabled = true; msg.textContent = "";
    const { data, error: err } = await client.rpc("keys_tenant_add_code", { p_code: code });
    if (err) { msg.textContent = await errorText(err); btn.disabled = false; return; }
    count = Number(data && data.count) || count + 1;
    ask();
    if (onAdded) onAdded();
  }
  form();
}
