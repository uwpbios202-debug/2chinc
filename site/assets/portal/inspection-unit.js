// Unit-specific inspection template: the shared template (/data/inspection-template.json) plus what is known about one unit
// (/data/inspection-units.json, keyed "<property id>|<unit>"). Used by the inspection page and the report page.
//   areaFacts: { areaId: "text shown under the room heading" }
//   patch:     { "areaId|Item name": { expect: n, fact: "text" } }   expect = how many the unit should have (the inspector counts)
//   addAreas:  [{ after: areaId, area: {...} }]                       a whole new room
//   addItems:  [{ area: areaId, after: "Item name", item: {...} }]   an extra item in an existing room
export async function unitTemplate(tpl, propId, unit) {
  let all = {};
  try { all = await fetch("/data/inspection-units.json").then((r) => r.ok ? r.json() : {}); } catch (e) { /* no unit file: generic template */ }
  const u = all[propId + "|" + unit];
  const t = JSON.parse(JSON.stringify(tpl));
  if (!u) return t;
  (u.addAreas || []).forEach((x) => { const i = t.areas.findIndex((a) => a.id === x.after); t.areas.splice(i < 0 ? t.areas.length : i + 1, 0, x.area); });
  (u.addItems || []).forEach((x) => { const a = t.areas.find((q) => q.id === x.area); if (!a) return; const i = a.items.findIndex((q) => q.name === x.after); a.items.splice(i < 0 ? a.items.length : i + 1, 0, x.item); });
  t.areas.forEach((a) => { if (u.areaFacts && u.areaFacts[a.id]) a.fact = u.areaFacts[a.id]; a.items.forEach((it) => { const p = (u.patch || {})[a.id + "|" + it.name]; if (p) Object.assign(it, p); }); });
  return t;
}
