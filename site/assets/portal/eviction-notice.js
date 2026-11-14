// Resident home: the running pay-or-vacate notice, next to the balance (11/9/2026).
// Before the eFile date: served date, unpaid RENT only (late fees are never part of a notice) and the cure date.
// After the case is recorded: "Eviction filed", case number and court date. Shows the certified mail receipt with a zoom button.
import { client, esc, fmtDate } from "/assets/portal/portal.js";

const money = (n) => "$" + Number(n || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const longDate = (d) => d ? new Date(String(d).slice(0, 10) + "T12:00:00").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", year: "numeric" }) : "";
const MEDIATION = "Mediate Milwaukee, (414) 939-8800 (free)";

async function signed(path) {
  const { data, error } = await client.storage.from("notices").createSignedUrl(path, 600);
  return error ? null : data.signedUrl;
}

function zoom(url) {
  const o = document.createElement("div");
  o.setAttribute("role", "dialog"); o.setAttribute("aria-label", "Certified mail receipt");
  o.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,.85);z-index:9999;display:flex;align-items:center;justify-content:center;padding:16px;cursor:zoom-out";
  o.innerHTML = `<img src="${url}" alt="Certified mail receipt" style="max-width:100%;max-height:100%;object-fit:contain;background:#fff;border-radius:6px">
    <button type="button" aria-label="Close" style="position:absolute;top:12px;right:12px;font-size:1.1rem;padding:6px 14px;border-radius:8px;border:0;cursor:pointer">✕ Close</button>`;
  const close = () => { o.remove(); document.removeEventListener("keydown", esc_); };
  const esc_ = (e) => { if (e.key === "Escape") close(); };
  o.onclick = close; document.addEventListener("keydown", esc_);
  document.body.appendChild(o);
}

export async function mountEvictionNotice(el) {
  if (!el) return;
  const { data: n, error } = await client.rpc("resident_eviction_status");
  if (error || !n) { el.innerHTML = ""; return; }
  const filed = !!n.case_number;
  const due = Number(n.rent_due || 0);
  let head, body;
  if (filed) {
    head = `⚖️ Eviction filed${n.case_filed_on ? " " + esc(fmtDate(n.case_filed_on)) : ""}`;
    body = `<p>Case number <b>${esc(n.case_number)}</b>.${n.court_at ? ` Court: <b>${esc(new Date(n.court_at).toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }))}</b>${n.court_place ? ", " + esc(n.court_place) : ""}.` : " We will tell you the court date."}</p>
      <p>Unpaid rent today: <b>${money(due)}</b>. Free help before court: ${MEDIATION}. Call us any time to talk about it.</p>`;
  } else if (due > 0) {
    const days = Math.round((new Date(String(n.cure_deadline).slice(0, 10)) - new Date(String(n.served_on).slice(0, 10))) / 864e5) + 1;
    head = `⚠️ ${days}-day notice to pay rent or vacate`;
    body = `<p>Served ${esc(longDate(n.served_on))}${n.service_method === "certified_mail" ? " by certified mail" : ""}. <b>Pay ${money(due)} rent by ${esc(longDate(n.cure_deadline))}</b> to stop an eviction filing.</p>
      <p class="sub2">Late fees are not part of this notice; only unpaid rent is. Free help: ${MEDIATION}.</p>`;
  } else {
    head = "✅ The rent on your notice is paid";
    body = `<p>Thank you. The rent named in the notice served ${esc(longDate(n.served_on))} is paid, so we will not file an eviction for it.</p>`;
  }
  const color = filed ? "#b3261e" : due > 0 ? "#b3261e" : "#2e7d32";
  el.innerHTML = `<div class="box" style="border-left:6px solid ${color}">
    <div style="display:flex;gap:16px;flex-wrap:wrap;align-items:flex-start">
      <div style="flex:1;min-width:220px"><h2 style="margin-top:0">${head}</h2>${body}
        ${n.pdf_path ? `<button class="btn2 ghost" type="button" data-evnotice>Open the notice</button>` : ""}</div>
      ${n.proof_path ? `<figure style="margin:0;text-align:center;max-width:160px">
        <img data-evthumb alt="Certified mail receipt" style="width:150px;height:auto;min-height:60px;border:1px solid #ccd;border-radius:6px;cursor:zoom-in;background:#f4f4f4">
        <figcaption class="sub2" style="margin:4px 0">Certified mail receipt</figcaption>
        <button class="btn2 ghost" type="button" data-evzoom>🔍 Zoom</button></figure>` : ""}
    </div></div>`;
  if (n.pdf_path) el.querySelector("[data-evnotice]").onclick = async () => {
    const u = await signed(n.pdf_path); if (u) window.open(u, "_blank", "noopener"); else alert("Couldn't open the notice. Try again.");
  };
  if (n.proof_path) {
    const u = await signed(n.proof_path);
    const img = el.querySelector("[data-evthumb]");
    if (!u || !img) return;
    img.src = u;
    img.onclick = () => zoom(u);
    el.querySelector("[data-evzoom]").onclick = () => zoom(u);
  }
}
