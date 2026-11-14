// Tenant's read-only copy of the staff pre-move-in inspection of their unit (Stephen, 11/5/2026).
//   mountInspectionDocs(el): the "Move-in inspection (by our staff)" box on the Documents tab (hidden when there is none).
//   mountInspectionReport(el, id): the full report, room by room, with photos (https://2ndchinc.org/resident/#inspection?id=...).
import { client, esc, fmtDate } from "/assets/portal/portal.js";
import { unitTemplate } from "/assets/portal/inspection-unit.js";

export async function mountInspectionDocs(el) {
  const { data, error } = await client.rpc("resident_inspections");
  if (error || !data || !data.length) { el.innerHTML = ""; return; }
  el.innerHTML = `<div class="box"><h2>Move-in inspection (by our staff)</h2>
    <p class="sub2">Our staff's room-by-room record of the unit's condition before you got the keys, with photos. It is your copy to keep.</p>
    ${data.map((x) => `<a class="folder" href="#inspection?id=${esc(x.id)}"><span>🔍</span><span style="flex:1"><b>Pre-move-in inspection</b>
      <div class="sub2">${esc(x.address || "")}${x.unit ? " · Unit " + esc(x.unit) : ""} · inspected ${fmtDate(x.inspected_on)}</div></span><span class="btn2 ghost">Open</span></a>`).join("")}</div>`;
}

const BADGE = { "OK": "✅", "Needs repair": "⚠️", "N/A": "➖" };

export async function mountInspectionReport(el, id) {
  el.innerHTML = `<p class="sub2">Loading…</p>`;
  const { data: r, error } = await client.rpc("resident_get_inspection", { p_id: id });
  if (error || !r) { el.innerHTML = `<div class="box"><p>This report isn't available. <a href="#documents">Back to Documents</a></p></div>`; return; }
  let tpl = { areas: [] };
  try { tpl = await unitTemplate(await fetch("/data/inspection-template.json").then((x) => x.json()), r.property_id, r.unit); } catch (e) { /* fall back to the keys below */ }
  const items = r.items || {}, used = new Set(), sections = [];
  tpl.areas.forEach((a) => {
    const rows = a.items.map((it) => { const k = a.id + "|" + it.name; if (!items[k]) return null; used.add(k); return [it.name, items[k]]; }).filter(Boolean);
    if (rows.length) sections.push([a.name, rows]);
  });
  const extra = Object.keys(items).filter((k) => !used.has(k)).map((k) => [k.split("|").slice(1).join("|") || k, items[k]]);
  if (extra.length) sections.push(["Other", extra]);
  let ok = 0, bad = 0;
  Object.values(items).forEach((x) => { if (x.s === "OK") ok++; else if (x.s === "Needs repair") bad++; });
  el.innerHTML = `<p><a href="#documents">← Documents</a> <button class="btn2 ghost" type="button" id="inspPrint" style="margin-left:10px">Print / save as PDF</button></p>
    <div class="box"><h2>Pre-move-in inspection</h2>
      <p>${esc(r.address || "")}${r.unit ? " · Unit " + esc(r.unit) : ""}<br>Inspected ${fmtDate(r.inspected_on)} by 2nd Chance Housing staff${r.submitted_at ? " · completed " + fmtDate(r.submitted_at) : ""}</p>
      <p class="sub2">${ok} items in good condition${bad ? `, ${bad} needing repair` : ""}. This is our record of the unit before you got the keys. Damage shown here is never charged to you.
      If you find anything that is not shown here, report it on your move-in checklist (<a href="#movein">Move-in</a>) by its due date.</p></div>
    ${sections.map(([name, rows]) => `<div class="box"><h2>${esc(name)}</h2>${rows.map(([n, x]) => `<div style="border-top:1px solid #e5e7eb;padding:8px 0">
        <div><b>${esc(n)}</b> ${BADGE[x.s] || ""} ${esc(x.l || x.s || "")}${x.c != null ? ` · count ${esc(x.c)}` : ""}${(x.loc || []).length ? ` · ${esc(x.loc.join(", "))}` : ""}</div>
        ${x.n ? `<div class="sub2">${esc(x.n)}</div>` : ""}
        ${(x.photos || []).length ? `<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px">${x.photos.map((p) => `<a target="_blank" rel="noopener" data-ip="${esc(p)}"><img data-ip="${esc(p)}" alt="Photo: ${esc(n)}" style="width:120px;height:90px;object-fit:cover;border-radius:6px;background:#eee"></a>`).join("")}</div>` : ""}
      </div>`).join("")}</div>`).join("")}`;
  el.querySelector("#inspPrint").onclick = () => window.print();
  const imgs = [...el.querySelectorAll("img[data-ip]")];
  for (let i = 0; i < imgs.length; i += 100) {
    const part = imgs.slice(i, i + 100);
    const { data } = await client.storage.from("inspections").createSignedUrls(part.map((x) => x.dataset.ip), 3600);
    (data || []).forEach((d, k) => { if (d.signedUrl) { part[k].src = d.signedUrl; part[k].parentElement.href = d.signedUrl; } });
  }
}
