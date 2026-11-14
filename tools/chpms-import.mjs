// CHPMS import: turns the research workbook (Milwaukee_Housing_Resources_CHPMS_vN.xlsx) into a seed migration.
//   node tools/chpms-import.mjs <workbook.xlsx> <out.sql> <version label, e.g. v2>
// No packages needed (reads the .xlsx zip with node:zlib). Keep the workbook itself out of git (data/ is ignored).
//
// Rules the generated SQL follows (Stephen, 11/12/2026, "History stays as it was" applies to our own edits too):
//  - Research columns are refreshed only on rows the office has NOT edited (staff_edited_at is null) and never on rows the
//    office added itself (is_local). Office fields (our_*) are never touched by an import.
//  - Rows that drop out of a newer workbook are left in place (never deleted by an import).
//  - Imported verification history keeps its own ids (VH001 ...); office checks live beside it.
// Run it again for a new version: it writes a new migration file; apply it with sh tools/deploy.sh db.

import { readFileSync, writeFileSync } from "node:fs";
import { inflateRawSync } from "node:zlib";

const [, , xlsxPath, outPath, version = "v2"] = process.argv;
if (!xlsxPath || !outPath) { console.error("usage: node tools/chpms-import.mjs <workbook.xlsx> <out.sql> <version>"); process.exit(1); }

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
    const header = (rows[0] || []).map((h) => (h == null ? null : String(h).trim()));
    out[name] = rows.slice(1).filter((r) => r.some((x) => x != null && String(x).trim() !== ""))
      .map((r) => Object.fromEntries(header.map((h, i) => [h, r[i] == null || String(r[i]).trim() === "" ? null : String(r[i]).trim()])));
  }
  return out;
}

const W = readWorkbook(xlsxPath);
const need = ["Organizations", "Programs", "Assistance_Types", "Program_Populations", "Eligibility", "Application_Procedures", "Contacts",
  "Service_Areas", "Landlord_Partnerships", "Referral_Relationships", "Referral_Pathways", "Funding_Map", "Funding_Relationships",
  "Gaps_Opportunities", "Source_Documents", "Verification_History", "Discovery_Log", "Conflicts_Log", "Merge_Log"];
for (const s of need) if (!W[s]) { console.error("Workbook is missing the sheet " + s); process.exit(1); }

// ---------- checks before writing anything ----------
const orgIds = new Set(W.Organizations.map((r) => r.org_id)), progIds = new Set(W.Programs.map((r) => r.program_id));
const problems = [];
const mustIn = (sheet, key, set) => W[sheet].forEach((r, i) => { if (!r[key] || !set.has(r[key])) problems.push(`${sheet} row ${i + 2}: ${key} ${r[key]} not found`); });
mustIn("Programs", "org_id", orgIds);
["Contacts", "Service_Areas", "Landlord_Partnerships"].forEach((s) => mustIn(s, "org_id", orgIds));
mustIn("Referral_Relationships", "from_org", orgIds); mustIn("Referral_Relationships", "to_org", orgIds);
["Assistance_Types", "Program_Populations", "Eligibility", "Application_Procedures"].forEach((s) => mustIn(s, "program_id", progIds));
const dup = (sheet, key) => { const seen = new Set(); W[sheet].forEach((r) => { if (seen.has(r[key])) problems.push(`${sheet}: duplicate ${key} ${r[key]}`); seen.add(r[key]); }); };
dup("Organizations", "org_id"); dup("Programs", "program_id"); dup("Contacts", "contact_id"); dup("Source_Documents", "source_id"); dup("Verification_History", "verification_id");
if (W.Funding_Map.length !== W.Funding_Relationships.length || W.Funding_Map.some((r, i) => r.program !== W.Funding_Relationships[i].program))
  problems.push("Funding_Map and Funding_Relationships no longer line up row by row (the import joins them by row)");
if (problems.length) { console.error("Import stopped:\n" + problems.join("\n")); process.exit(1); }

// ---------- SQL helpers ----------
const q = (v) => (v == null ? "null" : "'" + String(v).replace(/'/g, "''") + "'");
const qd = (v) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? q(v) + "::date" : "null");
const qi = (v) => (v != null && /^-?\d+$/.test(String(v)) ? String(v) : "null");
const yes = (v) => /^yes\b/i.test(String(v ?? ""));
const values = (rows) => rows.map((r) => "  (" + r.join(", ") + ")").join(",\n");
const POPS = ["Veterans", "Seniors", "Fixed income (SS/SSI/SSDI/VA)", "Families with children", "Experiencing homelessness", "At risk of eviction",
  "Disabilities", "Returning citizens", "Low-income working", "No current income"];
const saBy = Object.fromEntries(W.Service_Areas.map((r) => [r.org_id, r]));
const apBy = Object.fromEntries(W.Application_Procedures.map((r) => [r.program_id, r]));
const V = q(version);

const sql = [];
sql.push(`-- CHPMS research database ${version}, generated by tools/chpms-import.mjs from the workbook (do not edit by hand; regenerate).
-- ${W.Organizations.length} organizations, ${W.Programs.length} programs, ${W.Source_Documents.length} sources, ${W.Verification_History.length} verification entries.
-- Office edits are kept: research columns change only where staff_edited_at is null and is_local is false; our_* columns are never touched.
`);

// Organizations
const orgCols = ["org_id", "legal_name", "dba", "org_type", "classification_codes", "classifications", "priority_tier", "website", "physical_address",
  "main_phone", "general_email", "service_area", "service_area_source_ids", "languages", "accepts_outside_referrals", "verification_status",
  "verification_notes", "source_ids", "primary_source_url", "provenance", "date_accessed", "import_version"];
sql.push(`insert into chpms_orgs (${orgCols.join(", ")}) values\n` + values(W.Organizations.map((o) => [
  q(o.org_id), q(o.legal_name), q(o.dba), q(o.org_type), q(o.classification_codes), q(o.classifications), qi(o.priority_tier), q(o.website),
  q(o.physical_address), q(o.main_phone), q(o.general_email), q(saBy[o.org_id]?.service_area ?? o.service_area), q(saBy[o.org_id]?.source_ids),
  q(o.languages), q(o.accepts_outside_referrals), q(o.verification_status), q(o.verification_notes), q(o.source_ids), q(o.primary_source_url),
  q(o.provenance), qd(o.date_accessed), V])) +
  `\non conflict (org_id) do update set ${orgCols.slice(1).map((c) => `${c} = excluded.${c}`).join(", ")}, imported_at = now(), updated_at = now()
  where chpms_orgs.staff_edited_at is null and not chpms_orgs.is_local;\n`);

// Programs (+ Application_Procedures)
const progCols = ["program_id", "org_id", "program_name", "assistance_form", "payment_goes_to", "max_assistance", "months_covered", "frequency",
  "pays_security_deposit", "pays_arrears", "pays_application_fees", "moving_assistance", "current_status", "waiting_list", "application_window",
  "funding_dependency", "income_limits", "landlord_agreement_required", "eligibility_summary", "how_to_apply", "referral_requirement",
  "application_url", "intake_phone", "direct_financial", "is_direct_financial", "amount_publicly_disclosed", "verification_status", "source_ids",
  "notes", "provenance", "date_accessed", "self_referral", "agency_referral_required", "landlord_can_initiate", "application_method",
  "currently_open", "procedure_source_ids", "import_version"];
sql.push(`insert into chpms_programs (${progCols.join(", ")}) values\n` + values(W.Programs.map((p) => {
  const a = apBy[p.program_id] || {};
  return [q(p.program_id), q(p.org_id), q(p.program_name), q(p.assistance_form), q(p.payment_goes_to), q(p.max_assistance), q(p.months_covered),
    q(p.frequency), q(p.pays_security_deposit), q(p.pays_arrears), q(p.pays_application_fees), q(p.moving_assistance), q(p.current_status),
    q(p.waiting_list), q(p.application_window), q(p.funding_dependency), q(p.income_limits), q(p.landlord_agreement_required),
    q(p.eligibility_summary), q(p.how_to_apply), q(p.referral_requirement), q(p.application_url), q(p.intake_phone), q(p.is_direct_financial),
    yes(p.is_direct_financial) ? "true" : "false", q(p.amount_publicly_disclosed), q(p.verification_status), q(p.source_ids), q(p.notes),
    q(p.provenance), qd(p.date_accessed), q(a.self_referral), q(a.agency_referral_required), q(a.landlord_can_initiate), q(a.application_method),
    q(a.currently_open), q(a.source_ids), V];
})) + `\non conflict (program_id) do update set ${progCols.slice(1).map((c) => `${c} = excluded.${c}`).join(", ")}, imported_at = now(), updated_at = now()
  where chpms_programs.staff_edited_at is null and not chpms_programs.is_local;\n`);

// Children of programs and organizations: replaced only where the parent is not office-edited.
const freshProg = "(select program_id from chpms_programs where staff_edited_at is null and not is_local)";
const freshOrg = "(select org_id from chpms_orgs where staff_edited_at is null and not is_local)";
sql.push(`delete from chpms_program_assist where program_id in ${freshProg};
delete from chpms_program_pops where program_id in ${freshProg};
delete from chpms_eligibility where program_id in ${freshProg};
delete from chpms_contacts where org_id in ${freshOrg};
delete from chpms_landlord where org_id in ${freshOrg};\n`);
sql.push(`insert into chpms_program_assist (program_id, category, provided, source_ids)
select v.* from (values\n${values(W.Assistance_Types.map((r) => [q(r.program_id), q(r.assistance_category), yes(r.provided) ? "true" : "false", q(r.details_source_ids)]))}
) as v(program_id, category, provided, source_ids) where v.program_id in ${freshProg}
on conflict (program_id, category) do nothing;\n`);
const popRows = W.Program_Populations.flatMap((r) => POPS.filter((p) => yes(r[p])).map((p) => [q(r.program_id), q(p)]));
const extraPops = Object.keys(W.Program_Populations[0] || {}).filter((k) => !["program_id", "program_name", "organization", "verification_status"].includes(k) && !POPS.includes(k));
if (extraPops.length) { console.error("Program_Populations has columns the site does not know: " + extraPops.join(", ")); process.exit(1); }
sql.push(`insert into chpms_program_pops (program_id, population)
select v.* from (values\n${values(popRows)}
) as v(program_id, population) where v.program_id in ${freshProg}
on conflict do nothing;\n`);
sql.push(`insert into chpms_eligibility (elig_id, program_id, requirement_type, requirement, source_id)
select v.* from (values\n${values(W.Eligibility.map((r) => [q(r.elig_id), q(r.program_id), q(r.requirement_type), q(r.requirement), q(r.source_id)]))}
) as v(elig_id, program_id, requirement_type, requirement, source_id) where v.program_id in ${freshProg}
on conflict (elig_id) do nothing;\n`);
sql.push(`insert into chpms_contacts (contact_id, org_id, contact_type, name_if_public, phone, email, source_id)
select v.* from (values\n${values(W.Contacts.map((r) => [q(r.contact_id), q(r.org_id), q(r.contact_type), q(r.name_if_public), q(r.phone), q(r.email), q(r.source_id)]))}
) as v(contact_id, org_id, contact_type, name_if_public, phone, email, source_id) where v.org_id in ${freshOrg}
on conflict (contact_id) do nothing;\n`);
sql.push(`insert into chpms_landlord (org_id, works_with_private_landlords, recruits_landlords, landlord_network, pays_landlords_directly, landlord_incentives,
  tenant_placement, stabilization_support, partnership_contact, onboarding, source_ids)
select v.* from (values\n${values(W.Landlord_Partnerships.map((r) => [q(r.org_id), q(r.works_with_private_landlords), q(r.recruits_landlords), q(r.landlord_network),
  q(r.pays_landlords_directly), q(r.landlord_incentives), q(r.tenant_placement), q(r.stabilization_support), q(r.partnership_contact), q(r.onboarding), q(r.source_ids)]))}
) as v(org_id, works_with_private_landlords, recruits_landlords, landlord_network, pays_landlords_directly, landlord_incentives,
  tenant_placement, stabilization_support, partnership_contact, onboarding, source_ids) where v.org_id in ${freshOrg}
on conflict (org_id) do nothing;\n`);

// Whole-workbook tables: replaced on every import (the office does not edit these).
sql.push(`delete from chpms_org_links; delete from chpms_pathways; delete from chpms_funding; delete from chpms_gaps; delete from chpms_research_log;\n`);
sql.push(`insert into chpms_org_links (rel_id, from_org, to_org, relationship, source_ids) values\n${values(W.Referral_Relationships.map((r) =>
  [q(r.rel_id), q(r.from_org), q(r.to_org), q(r.relationship), q(r.source_ids)]))};\n`);
sql.push(`insert into chpms_pathways (population, step, step_name, what_happens, responsible_organizations) values\n${values(W.Referral_Pathways.map((r) =>
  [q(r.population), qi(r.step), q(r.step_name), q(r.what_happens), q(r.responsible_organizations)]))};\n`);
sql.push(`insert into chpms_funding (funding_id, funding_level, funding_agency, program, available_to, receiving_org, service_delivery_org, population,
  assistance_type, funding_period, accepting_apps_or_awarding, source_ids) values\n${values(W.Funding_Relationships.map((r, i) => {
  const m = W.Funding_Map[i];
  return [q(r.funding_id), q(m.funding_level), q(r.funding_agency), q(r.program), q(m.available_to), q(r.receiving_org), q(r.service_delivery_org),
    q(r.population), q(r.assistance_type), q(r.funding_period ?? m.period_amount), q(r.accepting_apps_or_awarding), q(r.source_ids ?? m.source_ids)];
}))};\n`);
sql.push(`insert into chpms_gaps (seq, kind, finding, source_ids) values\n${values(W.Gaps_Opportunities.map((r, i) =>
  [String(i + 1), q(r.gap_or_opportunity_type), q(r.finding), q(r.source_ids)]))};\n`);
sql.push(`insert into chpms_sources (source_id, title, url, publisher, source_type, date_accessed) values\n${values(W.Source_Documents.map((r) =>
  [q(r.source_id), q(r.title), q(r.url), q(r.publisher), q(r.source_type), qd(r.date_accessed)]))}
on conflict (source_id) do update set title = excluded.title, url = excluded.url, publisher = excluded.publisher, source_type = excluded.source_type,
  date_accessed = excluded.date_accessed;\n`);
const logRows = [
  ...W.Discovery_Log.map((r) => ["'discovery'", q(r.entry_type), q(JSON.stringify(r)) + "::jsonb"]),
  ...W.Conflicts_Log.map((r) => ["'conflict'", q(r.resolution && /^resolved/i.test(r.resolution) ? "Resolved" : "Open"), q(JSON.stringify(r)) + "::jsonb"]),
  ...W.Merge_Log.map((r) => ["'merge'", q(r.entry_type), q(JSON.stringify(r)) + "::jsonb"]),
].map((r, i) => [String(i + 1), ...r]);
sql.push(`insert into chpms_research_log (seq, log, entry_type, data) values\n${values(logRows)};\n`);
sql.push(`insert into chpms_checks (verification_id, record_type, record_id, checked_on, status, method, notes, by_role, from_import)
select v.verification_id, v.record_type, v.record_id, v.checked_on, v.status, v.method, v.notes, 'research', true from (values\n${values(W.Verification_History.map((r) =>
  [q(r.verification_id), q(/^prog/i.test(r.record_type) ? "program" : "org"), q(r.record_id), qd(r.date), q(r.status), q(r.method), q(r.notes)]))}
) as v(verification_id, record_type, record_id, checked_on, status, method, notes)
on conflict (verification_id) do nothing;\n`);
const readme = W.README_Summary.map((r) => Object.values(r).filter(Boolean).join(" | ")).filter((t) => t.length > 40 && !/live formulas|^\d+\.|^\s*…|^(Organizations|Programs|Open conflicts) /.test(t));
sql.push(`insert into portal_settings (key, value) values ('chpms_version', ${V}), ('chpms_readme', ${q(readme.join("\n"))})
on conflict (key) do update set value = excluded.value;\n`);

// Real people's emails stay off GitHub (CLAUDE.md: a migration that lists real people's emails is local only). An email is a person's
// when a Contacts row names someone (name_if_public). The committed file carries a placeholder; a second, local-only file
// (gitignored: *_chpms_*_local_only.sql) puts the real address back. Apply both with supabase db push from this PC.
let text = sql.join("\n");
const emailRe = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const personal = [...new Set(W.Contacts.filter((c) => c.name_if_public).flatMap((c) => String(c.email ?? "").match(emailRe) ?? []))];
const restore = [];
personal.forEach((email, i) => {
  const ph = `[named contact email kept at the office ${i + 1}]`;   // no quote marks: it is swapped into already-quoted SQL text
  text = text.split(email).join(ph);
  const cols = { chpms_orgs: ["general_email", "verification_notes", "main_phone"], chpms_programs: ["how_to_apply", "notes", "intake_phone", "application_method"],
    chpms_contacts: ["email", "phone"], chpms_checks: ["notes"] };
  for (const [t, cs] of Object.entries(cols)) for (const c of cs)
    restore.push(`update ${t} set ${c} = replace(${c}, ${q(ph)}, ${q(email)}) where ${c} like ${q("%" + ph + "%")};`);
});
writeFileSync(outPath, text);
if (restore.length) {
  const localPath = outPath.replace(/\.sql$/, "").replace(/(\d{14})_/, (m, d) => String(BigInt(d) + 1000n) + "_") + "_named_contacts_local_only.sql";
  writeFileSync(localPath, `-- LOCAL ONLY (gitignored, never commit): real people's published emails for the CHPMS directory ${version}.\n` + restore.join("\n") + "\n");
  console.log(`Wrote ${localPath} (local only): ${personal.length} personal email(s) kept off GitHub.`);
}
console.log(`Wrote ${outPath}: ${W.Organizations.length} orgs, ${W.Programs.length} programs, ${W.Assistance_Types.length} assistance rows, ${popRows.length} population links, ` +
  `${W.Eligibility.length} eligibility, ${W.Contacts.length} contacts, ${W.Landlord_Partnerships.length} landlord, ${W.Referral_Relationships.length} links, ` +
  `${W.Referral_Pathways.length} pathway steps, ${W.Funding_Relationships.length} funding, ${W.Gaps_Opportunities.length} gaps, ${W.Source_Documents.length} sources, ` +
  `${logRows.length} log, ${W.Verification_History.length} history.`);
