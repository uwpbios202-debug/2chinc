// Landlord Recruitment Database import: turns Milwaukee_Independent_Landlord_DB_vN.xlsx into a seed migration.
//   node tools/landlord-db-import.mjs <workbook.xlsx> <out.sql> <version label, e.g. v0.2>
// No packages needed. Keep the workbook itself out of git (data/ is ignored). Schema: migration 20261119420000.
// Rules the generated SQL follows (same as the CHPMS import):
//  - Research columns are refreshed only on rows the office has NOT edited (staff_edited_at is null) and never on rows the
//    office added (is_local). Office / Navigator columns (our_*, claims, sign-ups, opt-ins, do_not_contact) are never touched.
//  - Rows that drop out of a newer workbook are left in place (never deleted). The Outreach_Log example row is never imported.
//  - Contact details: only what the workbook has (published business lines and addresses); phone/email opt-ins come from outreach.

import { readFileSync, writeFileSync } from "node:fs";
import { inflateRawSync } from "node:zlib";


// ---------- minimal zip reader ----------
function unzip(buf) {
  let eocd = buf.length - 22;
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error("Not a zip file");
  const count = buf.readUInt16LE(eocd + 10), cdOff = buf.readUInt32LE(eocd + 16);
  const files = {};
  let p = cdOff;
  for (let i = 0; i < count; i++) {
    const method = buf.readUInt16LE(p + 10), csize = buf.readUInt32LE(p + 20);
    const nlen = buf.readUInt16LE(p + 28), xlen = buf.readUInt16LE(p + 30), clen = buf.readUInt16LE(p + 32), lho = buf.readUInt32LE(p + 42);
    const name = buf.toString("utf8", p + 46, p + 46 + nlen);
    const lnlen = buf.readUInt16LE(lho + 26), lxlen = buf.readUInt16LE(lho + 28);
    const data = buf.subarray(lho + 30 + lnlen + lxlen, lho + 30 + lnlen + lxlen + csize);
    files[name] = method === 0 ? Buffer.from(data) : method === 8 ? inflateRawSync(data) : null;
    p += 46 + nlen + xlen + clen;
  }
  return files;
}

// ---------- minimal xlsx reader ----------
const dec = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16))).replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n)).replace(/&amp;/g, "&");
function readWorkbook(path) {
  const z = unzip(readFileSync(path));
  const txt = (n) => { const f = z[n]; if (!f) throw new Error("Missing " + n); return f.toString("utf8"); };
  const shared = z["xl/sharedStrings.xml"]
    ? [...txt("xl/sharedStrings.xml").matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => dec([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join("")))
    : [];
  const rels = {};
  for (const m of txt("xl/_rels/workbook.xml.rels").matchAll(/<Relationship\b([^>]*)\/?>/g)) {
    const id = /Id="([^"]+)"/.exec(m[1])?.[1], target = /Target="([^"]+)"/.exec(m[1])?.[1];
    if (id && target) rels[id] = target.replace(/^\/?xl\//, "");
  }
  const col = (c) => [...c].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1;
  const out = {};
  for (const m of txt("xl/workbook.xml").matchAll(/<sheet\b([^>]*)\/>/g)) {
    const name = dec(/name="([^"]+)"/.exec(m[1])[1]), rid = /r:id="([^"]+)"/.exec(m[1])[1];
    const rows = [];
    for (const r of txt("xl/" + rels[rid]).matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
      const row = [];
      for (const c of r[1].matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const ref = /r="([A-Z]+)\d+"/.exec(c[1])[1], t = /t="([^"]+)"/.exec(c[1])?.[1], body = c[2] || "";
        let v = /<v>([\s\S]*?)<\/v>/.exec(body)?.[1];
        if (t === "s") v = shared[+v];
        else if (t === "inlineStr") v = dec([...body.matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((x) => x[1]).join(""));
        else if (v !== undefined) v = dec(v);
        row[col(ref)] = v ?? null;
      }
      rows.push(row);
    }
    const header = Array.from(rows[0] || []).map((h) => (h == null ? null : String(h).trim()));
    out[name] = rows.slice(1).filter((r) => r.some((x) => x != null && String(x).trim() !== ""))
      .map((r) => Object.fromEntries(header.map((h, i) => [h ?? "_col" + i, r[i] == null || String(r[i]).trim() === "" ? null : String(r[i]).trim()])));
  }
  return out;
}

const [, , xlsxPath, outPath, version = "v0.2"] = process.argv;
if (!xlsxPath || !outPath) { console.error("usage: node tools/landlord-db-import.mjs <workbook.xlsx> <out.sql> <version>"); process.exit(1); }
const W = readWorkbook(xlsxPath);
const need = ["Landlord_Records", "Recruitment_Channels", "Business_Owner_Networks", "Property_Managers", "Large_Networks", "Landlord_Properties",
  "Gap_Analysis", "Market_Profile", "Data_Sources", "Build_Steps", "Outreach_Log", "Sources"];
for (const s of need) if (!W[s]) { console.error("Workbook is missing the sheet " + s); process.exit(1); }

const q = (v) => (v == null ? "null" : "'" + String(v).replace(/'/g, "''") + "'");
const qd = (v) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? q(v) + "::date" : "null");
const qi = (v) => (v != null && /^-?\d+$/.test(String(v)) ? String(v) : "null");
const qn = (v) => (v != null && /^-?\d+(\.\d+)?$/.test(String(v)) ? String(v) : "null");
const values = (rows) => rows.map((r) => "  (" + r.join(", ") + ")").join(",\n");
const V = q(version);
const problems = [];
const dup = (sheet, key) => { const seen = new Set(); W[sheet].forEach((r) => { if (seen.has(r[key])) problems.push(`${sheet}: duplicate ${key} ${r[key]}`); seen.add(r[key]); }); };
dup("Landlord_Records", "landlord_id"); dup("Recruitment_Channels", "channel_id"); dup("Business_Owner_Networks", "id");
dup("Property_Managers", "pm_id"); dup("Sources", "source_id"); dup("Data_Sources", "source_id"); dup("Landlord_Properties", "property_id");
const chIds = new Set(W.Recruitment_Channels.map((r) => r.channel_id)), llIds = new Set(W.Landlord_Records.map((r) => r.landlord_id));
W.Landlord_Records.forEach((r) => { if (r.recruitment_channel && !chIds.has(r.recruitment_channel)) problems.push(`Landlord_Records ${r.landlord_id}: channel ${r.recruitment_channel} not found`); });
W.Landlord_Properties.forEach((r) => { if (!llIds.has(r.landlord_id)) problems.push(`Landlord_Properties ${r.property_id}: landlord ${r.landlord_id} not found`); });
// Links a Property_Managers / Large_Networks row to its Landlord_Records row by name (exact, or the record name followed by a space).
const byName = (name) => {
  const n = String(name).toLowerCase();
  const hits = W.Landlord_Records.filter((l) => n === l.owner_or_company_name.toLowerCase() || n.startsWith(l.owner_or_company_name.toLowerCase() + " "));
  return hits.length === 1 ? hits[0].landlord_id : null;
};
const pmLinks = W.Property_Managers.map((m) => { const id = byName(m.company); if (!id) problems.push(`Property_Managers ${m.pm_id}: no single matching landlord row`); return id; });
const netLinks = W.Large_Networks.map((n) => { const id = byName(n.owner_network); if (!id) problems.push(`Large_Networks ${n.owner_network}: no single matching landlord row`); return id; });
const realLog = W.Outreach_Log.filter((r) => r.log_id && !/^EXAMPLE/i.test(r.log_id));
if (realLog.length) problems.push(`Outreach_Log has ${realLog.length} real rows; this import does not load outreach (log it on the site).`);
if (problems.length) { console.error("Import stopped:\n" + problems.join("\n")); process.exit(1); }

const sql = [];
sql.push(`-- Landlord Recruitment Database ${version}, generated by tools/landlord-db-import.mjs from the workbook (do not edit by hand; regenerate).
-- ${W.Landlord_Records.length} landlord records, ${W.Landlord_Properties.length} properties, ${W.Recruitment_Channels.length} channels, ${W.Business_Owner_Networks.length} business networks,
-- ${W.Property_Managers.length} property managers, ${W.Large_Networks.length} large networks, ${W.Sources.length} sources. Outreach_Log example row not imported.
-- Office edits are kept: research columns change only where staff_edited_at is null and is_local is false.
`);
const upsert = (table, key, cols, rows, guard) => sql.push(`insert into ${table} (${cols.join(", ")}) values\n${values(rows)}\non conflict (${key}) do update set ${cols.filter((c) => c !== key).map((c) => `${c} = excluded.${c}`).join(", ")}, imported_at = now()${guard ? "\n  where " + guard : ""};\n`);

upsert("lrd_sources", "source_id", ["source_id", "title", "url", "source_type", "import_version"],
  W.Sources.map((r) => [q(r.source_id), q(r.title), q(r.url), q(r.type), V]));

upsert("lrd_channels", "channel_id", ["channel_id", "channel", "what_it_is", "contact_access", "how_used", "verification_status", "source_ids", "import_version"],
  W.Recruitment_Channels.map((r) => [q(r.channel_id), q(r.channel), q(r.what_it_is), q(r.contact_access), q(r.how_2nd_Chance_uses_it), q(r.verification_status), q(r.source_ids), V]),
  "lrd_channels.staff_edited_at is null");

upsert("lrd_business_networks", "network_id", ["network_id", "network", "who_belongs", "contact", "how_to_use", "verification_status", "source_url", "import_version"],
  W.Business_Owner_Networks.map((r) => [q(r.id), q(r.network), q(r.who_belongs), q(r.contact), q(r.how_to_use), q(r.verification_status), q(r.source_url), V]),
  "lrd_business_networks.staff_edited_at is null");

const llCols = ["landlord_id", "owner_or_company_name", "segment", "entity_type", "size_tier", "independent_flag", "units_known", "parcels_known", "parcels_note",
  "tax_bill_or_business_address", "local_status", "accepts_vouchers", "lift_member", "recruitment_channel", "contact_status",
  "eviction_filings_per_100_units", "code_violations_per_100_units", "screening_result", "do_not_partner_flag", "do_not_partner",
  "verification_status", "source_ids", "date_added", "import_version"];
upsert("lrd_landlords", "landlord_id", llCols, W.Landlord_Records.map((r) => {
  const pk = r.parcels_known, pkInt = pk != null && /^\d+$/.test(pk);
  return [q(r.landlord_id), q(r.owner_or_company_name), q(r.segment), q(r.entity_type), q(r.size_tier), q(r.independent_flag), qi(r.units_known),
    pkInt ? pk : "null", pkInt ? "null" : q(pk), q(r.tax_bill_or_business_address), q(r.local_status), q(r.accepts_vouchers), q(r.lift_member),
    q(r.recruitment_channel), q(r.contact_status ?? "Not contacted"), qn(r.eviction_filings_per_100_units), qn(r.code_violations_per_100_units),
    q(r.screening_result), q(r.do_not_partner_flag), /^yes\b/i.test(r.do_not_partner_flag ?? "") ? "true" : "false",
    q(r.verification_status), q(r.source_ids), qd(r.date_added), V];
}), "lrd_landlords.staff_edited_at is null and not lrd_landlords.is_local");
// The workbook's contact status only fills a lead nobody has worked yet (no outreach, no claim, no sign-up, no do-not-contact).
sql[sql.length - 1] = sql[sql.length - 1].replace("contact_status = excluded.contact_status",
  "contact_status = case when lrd_landlords.claimed_by_navigator is null and lrd_landlords.nav_landlord_id is null and not lrd_landlords.do_not_contact\n    and not exists (select 1 from lrd_outreach o where o.landlord_id = lrd_landlords.landlord_id) then excluded.contact_status else lrd_landlords.contact_status end");

if (W.Landlord_Properties.length) upsert("lrd_properties", "property_id", ["property_id", "landlord_id", "taxkey", "property_address", "units", "land_use_code", "owner_occupied", "neighborhood", "source", "date_added", "import_version"],
  W.Landlord_Properties.map((r) => [q(r.property_id), q(r.landlord_id), q(r.taxkey), q(r.property_address), qi(r.units), q(r.land_use_code), q(r.owner_occupied), q(r.neighborhood), q(r.source), qd(r.date_added), V]));
else sql.push("-- Landlord_Properties is empty in this workbook version (filled after the City MPROP / absentee-owner upload).\n");

upsert("lrd_property_managers", "pm_id", ["pm_id", "company", "focus", "address_listed", "source_ids", "landlord_id", "import_version"],
  W.Property_Managers.map((r, i) => [q(r.pm_id), q(r.company), q(r.focus), q(r.address_listed), q(r.source_ids), q(pmLinks[i]), V]));

upsert("lrd_large_networks", "network_key", ["network_key", "rank", "owner_network", "parcels", "units", "flag", "source_id", "landlord_id", "import_version"],
  W.Large_Networks.map((r, i) => [q(/^\d+$/.test(r.rank ?? "") ? "rank-" + r.rank : "unranked-" + netLinks[i]), qi(r.rank), q(r.owner_network),
    q(r.parcels), q(r.units), q(r.flag), q(r.source_id), q(netLinks[i]), V]));

// Market profile: the derived estimate is computed the way the workbook formula does: ROUND(networks * (1 - share owning >25 units), -2).
const mp = W.Market_Profile, num = (m) => Number(mp.find((r) => r.metric.startsWith(m))?.value);
upsert("lrd_market_profile", "metric", ["metric", "value", "note", "source_id", "is_derived", "import_version"], mp.map((r) => {
  let v = r.value; const derived = /DERIVED/.test(r.metric);
  if (derived) {
    const nets = num("Ownership networks"), share = num("Share of networks owning >25 units");
    if (!Number.isFinite(nets) || !Number.isFinite(share)) { console.error("Cannot compute the derived estimate"); process.exit(1); }
    v = String(Math.round(nets * (1 - share) / 100) * 100);
  }
  return [q(r.metric), qn(v), q(r.note), q(r.source_id), derived ? "true" : "false", V];
}));

upsert("lrd_data_sources", "source_id", ["source_id", "source", "what_it_contains", "access", "use_in_db", "adopted", "import_version"],
  W.Data_Sources.map((r) => [q(r.source_id), q(r.source), q(r.what_it_contains), q(r.access), q(r.use_in_this_database), /^NOT ADOPTED/i.test(r.use_in_this_database ?? "") ? "false" : "true", V]));

const gapActionCol = Object.keys(W.Gap_Analysis[0] || {}).find((k) => /^action/.test(k));
upsert("lrd_gap_analysis", "id", ["id", "doc", "claim_or_item", "verdict", "reason", "action_taken", "import_version"],
  W.Gap_Analysis.map((r, i) => [String(i + 1), q(r.doc), q(r.claim_or_item), q(r.verdict), q(r.reason), q(r[gapActionCol]), V]));

upsert("lrd_build_steps", "step", ["step", "name", "action", "step_owner", "import_version"],
  W.Build_Steps.map((r) => [qi(r.step), q(r.name), q(r.action), q(r.owner), V]));

writeFileSync(outPath, sql.join("\n"));
console.log(`Wrote ${outPath}: ${W.Landlord_Records.length} landlords, ${W.Landlord_Properties.length} properties, ${W.Recruitment_Channels.length} channels, ${W.Business_Owner_Networks.length} networks, ${W.Property_Managers.length} managers, ${W.Large_Networks.length} large networks, ${mp.length} market metrics, ${W.Data_Sources.length} data sources, ${W.Gap_Analysis.length} gap rows, ${W.Build_Steps.length} steps, ${W.Sources.length} sources.`);
