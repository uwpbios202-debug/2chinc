// "Text the HVAC technician" card (resident Requests and owner Repairs). Database: hvac_tech_mine() in
// supabase/migrations/20261118290000_hvac_technician.sql. The site has no SMS: the button opens the person's own phone with the
// first text filled in, ONLY the address and who to call to get in, and they send it themselves. Owners who pay him see a Zelle Pay card.
import { client, esc } from "/assets/portal/portal.js";

const CSS = `
.hv{background:#fff;border:2px solid #2e7d1f;border-radius:12px;padding:14px 16px;margin:0 0 14px}
.hv h2,.hv h3{margin:0 0 6px;font-size:1.15rem}.hv p{margin:6px 0}.hv-sub{color:#5b6573;font-size:.9rem}
.hv-warn{background:#fff3cd;border-radius:8px;padding:8px 10px;color:#5c3d00;font-size:.92rem;margin:8px 0}
.hv-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin:8px 0}
.hv label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}
.hv input,.hv select{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.hv-msg{background:#f4f7f2;border-radius:8px;padding:8px 10px;font-size:.92rem;white-space:pre-wrap}
.hv-btn{display:inline-block;background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:11px 22px;font-weight:700;cursor:pointer;text-decoration:none;margin:6px 8px 0 0}
.hv-btn.alt{background:#fff;color:#2e7d1f;border:2px solid #2e7d1f}.hv-btn[aria-disabled="true"]{opacity:.45;pointer-events:none}
.hv-pay{border-top:1px solid #e3e8e0;margin-top:12px;padding-top:10px}`;

const digits = (p) => String(p || "").replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "");

export async function mountHvac(el) {
  if (!el) return;
  const { data, error } = await client.rpc("hvac_tech_mine");
  const units = (!error && data?.units) || [];
  if (!units.length) { el.innerHTML = ""; return; }
  if (!document.getElementById("hv-css")) { const s = document.createElement("style"); s.id = "hv-css"; s.textContent = CSS; document.head.appendChild(s); }
  const tel = digits(data.phone), pays = units.some((u) => u.pays), first = units[0], staff = units.some((u) => u.role === "staff");
  const payUnits = units.filter((u) => u.pays).map((u) => "Unit " + esc(u.unit)).join(", ");
  const ownerPaid = staff ? units.filter((u) => !u.pays).map((u) => "Unit " + esc(u.unit)).join(", ") : "";
  el.innerHTML = `<div class="hv">
    <h2>🔥 Heat or air conditioning problem? Text the HVAC technician</h2>
    <p><b>${esc(data.name)}</b> · ${esc(data.phone)}</p>
    <p class="hv-sub">Text him first. Your first text has <b>only</b> the address and who to call to get into the building and the unit. This button opens your own phone with that text filled in; you press send. The website does not send texts.</p>
    <div class="hv-warn"><b>Someone must be on site when the technician arrives</b> to let him into the building and the unit.</div>
    <div class="hv-grid">
      ${units.length > 1 ? `<label>Which unit?<select data-hv="unit">${units.map((u, i) => `<option value="${i}">Unit ${esc(u.unit)}</option>`).join("")}</select></label>` : ""}
      <label>Who should he call to get in?<input data-hv="name" maxlength="80" value="${esc(first.my_name || "")}"></label>
      <label>Their phone number<input data-hv="phone" type="tel" maxlength="20" value="${esc(first.my_phone || "")}"></label>
    </div>
    <p class="hv-sub" style="margin-bottom:2px">Your text will say:</p>
    <div class="hv-msg" data-hv="preview"></div>
    <a class="hv-btn" data-hv="sms" href="#">💬 Text ${esc(data.name.split(" ")[0])}</a><button class="hv-btn alt" type="button" data-hv="copy">Copy the text</button>
    <span class="hv-sub" data-hv="copied" role="status"></span>
    <p class="hv-sub">On a computer? Copy the text and send it from your phone to ${esc(data.phone)}. For an emergency (a gas smell or fire), leave and call 911.</p>
    ${pays ? `<div class="hv-pay"><h3>💵 Pay</h3>
      ${staff ? `<p><b>2nd Chance pays ${esc(data.name)}</b> for ${payUnits}. He accepts <b>Zelle</b>. Send it from 2nd Chance's bank <b>when the work is done</b>.${ownerPaid ? ` The owners pay him themselves for ${ownerPaid}.` : ""}</p>`
        : `<p>For your unit${units.filter((u) => u.pays).length > 1 ? "s" : ""} (${payUnits}), <b>you pay ${esc(data.name)} yourself</b>. He accepts <b>Zelle</b>. Send it from your own bank's app <b>when the work is done</b>.</p>`}
      <p>${data.zelle ? `Zelle to: <b>${esc(data.zelle)}</b>.` : `Ask him by text which phone number or email his Zelle uses.`} Before you send, check that the name your bank shows is <b>${esc(data.name)}</b>.${staff ? "" : " 2nd Chance does not take or pass on this payment."}</p>
      <button class="hv-btn alt" type="button" data-hv="paybtn">Pay ${esc(data.name.split(" ")[0])} by Zelle</button>
      <div class="hv-sub" data-hv="payhelp" hidden><p><b>How to pay by Zelle:</b></p><ol>
        <li>Open ${staff ? "2nd Chance's" : "your"} bank's app and choose <b>Zelle</b> (or "Send money").</li>
        <li>Enter ${data.zelle ? `<b>${esc(data.zelle)}</b>` : "the phone number or email he gives you"} and check the name shown is ${esc(data.name)}.</li>
        <li>Enter the amount he charged for the finished work and send it. Keep the confirmation.</li></ol></div></div>` : ""}
  </div>`;

  const q = (k) => el.querySelector(`[data-hv="${k}"]`);
  const unit = () => units[q("unit") ? Number(q("unit").value) : 0];
  const text = () => `HVAC service needed at ${unit().address}. To get into the building and unit, call ${q("name").value.trim()} at ${q("phone").value.trim()}.`;
  const sync = () => {
    const ok = q("name").value.trim().length > 1 && digits(q("phone").value).length >= 10;
    q("preview").textContent = ok ? text() : "Fill in who to call and their phone number.";
    q("sms").href = ok ? `sms:+1${tel}?&body=${encodeURIComponent(text())}` : "#";
    q("sms").setAttribute("aria-disabled", ok ? "false" : "true");
    q("copy").disabled = !ok;
  };
  ["name", "phone"].forEach((k) => q(k).addEventListener("input", sync));
  if (q("unit")) q("unit").addEventListener("change", sync);
  q("copy").onclick = async () => {
    try { await navigator.clipboard.writeText(text()); q("copied").textContent = "Copied."; } catch { q("copied").textContent = "Select the text above and copy it."; }
  };
  if (q("paybtn")) q("paybtn").onclick = () => { q("payhelp").hidden = !q("payhelp").hidden; };
  sync();
}

// True when the signed-in person has a unit this technician serves (owner portal shows the Repairs tab).
export async function hasHvac() {
  const { data, error } = await client.rpc("hvac_tech_mine");
  return !error && (data?.units || []).length > 0;
}
