// Human Mirror database #3, Milwaukee Cost-of-Living Benchmarks: turns the workbook into a seed migration.
//   node tools/cost-benchmarks-import.mjs <workbook.xlsx> <out.sql> <version label, e.g. v0.3>
// Schema: supabase/migrations/20261119750000_mirror_cost_benchmarks.sql. Reference data: a newer workbook replaces every row.
// Checks before writing (the workbook's own rules): ids unique, every category one of the 12 keys, every source_id exists,
// per_month = per_year / 12 and per_day = per_year / 365 where given, and each Daily_Number_Examples total adds up.

import { writeFileSync } from "node:fs";
import { readWorkbook } from "./lib/xlsx.mjs";

const [, , xlsxPath, outPath, version = "v0.3"] = process.argv;
if (!xlsxPath || !outPath) { console.error("usage: node tools/cost-benchmarks-import.mjs <workbook.xlsx> <out.sql> <version>"); process.exit(1); }
const W = readWorkbook(xlsxPath);
for (const s of ["Benchmarks", "Daily_Number_Examples", "Sources", "Conflicts_Log"]) if (!W[s]) { console.error("Missing sheet " + s); process.exit(1); }

const CATS = ["housing", "utilities", "food", "transportation", "healthcare", "personal_care", "clothing", "communication", "household", "financial", "development", "future"];
const q = (v) => (v == null || v === "" ? "null" : "'" + String(v).replace(/'/g, "''") + "'");
const num = (v) => (v == null || v === "" || isNaN(Number(v)) ? "null" : String(Number(v)));
const qd = (v) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? q(v) + "::date" : "null");
const arr = (s) => (s ? String(s).split(/[;,]/).map((x) => x.trim()).filter(Boolean) : []);
const qa = (a) => (a.length ? "array[" + a.map(q).join(", ") + "]::text[]" : "'{}'::text[]");
const fail = [];

const src = new Set(W.Sources.map((s) => s.source_id));
const ids = new Set();
// A short name for the cost line the person may add ("Use this amount"); they can change it.
function shortLabel(r) {
  const t = r.item.replace(/\s+DERIVED$/, "");
  if (/^Gross rent:/.test(t)) {
    const size = t.split(",").pop().trim();
    if (/single-room occupancy/.test(t)) return "Rent for a room (HUD single-room rent)";
    return (/NOT in effect/.test(t) ? "Rent, HUD FY2027 (not in effect), " : "Rent, HUD Fair Market Rent, ") + size;
  }
  let m = /^ALICE Household Survival Budget, Milwaukee County: ([^(]+)/.exec(t);
  if (m) return m[1].trim() + " (ALICE survival budget)";
  m = /^(.+?) \(MIT 'typical expense'/.exec(t);
  if (m) return m[1].replace(/ \(MIT:.*$/, "").trim() + " (MIT typical)";
  if (/^We Energies typical residential electric bill/.test(t)) return "Electric bill, typical (660 kWh a month)";
  m = /^IRS National Standard allowance: ([^(]+)/.exec(t);
  if (m) return m[1].trim() + " (IRS standard)";
  m = /^BLS Consumer Expenditure, Midwest average per consumer unit \(2\.4 persons\): (.+)$/.exec(t);
  if (m) return m[1].trim() + " (Midwest average)";
  const cut = t.split(/ \(|\. /)[0];
  return cut.length > 90 ? cut.slice(0, 87).trimEnd() + "..." : cut;
}

const rows = W.Benchmarks.map((r, i) => {
  if (ids.has(r.benchmark_id)) fail.push("duplicate " + r.benchmark_id);
  ids.add(r.benchmark_id);
  if (!CATS.includes(r.category)) fail.push(r.benchmark_id + " category " + r.category);
  if (!["survival", "stability", "aspirational"].includes(r.level)) fail.push(r.benchmark_id + " level " + r.level);
  for (const s of arr(r.source_ids)) if (!src.has(s)) fail.push(r.benchmark_id + " source " + s);
  if (r.per_year && r.per_month && Math.abs(r.per_year / 12 - r.per_month) > 0.01) fail.push(r.benchmark_id + " per_month");
  if (r.per_year && r.per_day && Math.abs(r.per_year / 365 - r.per_day) > 0.01) fail.push(r.benchmark_id + " per_day");
  return `  (${q(r.benchmark_id)}, ${q(r.category)}, ${q(r.item)}, ${q(shortLabel(r))}, ${q(r.level)}, ${q(r.household_size || "all households")}, ${num(r.amount_as_published)}, ${q(r.unit)}, ${q(r.frequency)}, ${num(r.one_time_amount)}, ${num(r.per_year)}, ${num(r.per_month)}, ${num(r.per_day)}, ${q(r.formula)}, ${q(r.geography)}, ${q(r.as_of_date)}, ${/^yes/i.test(r.poverty_premium || "") ? "true" : "false"}, ${q(r.cheaper_alternative)}, ${q(r.verification_status)}, ${qa(arr(r.source_ids))}, ${i + 1}, ${q(version)})`;
});
const byId = Object.fromEntries(W.Benchmarks.map((r) => [r.benchmark_id, r]));
const ex = W.Daily_Number_Examples.map((e, i) => {
  const used = (String(e.benchmark_ids_used).match(/COL-\d{3}/g) || []);
  for (const u of used) if (!byId[u]) fail.push("example " + (i + 1) + " uses missing " + u);
  const sum = used.reduce((t, u) => t + Number(byId[u]?.per_year || 0), 0);
  if (Math.abs(sum - Number(e.total_per_year)) > 0.5) fail.push(`example ${i + 1} adds to ${sum}, not ${e.total_per_year}`);
  const note = /:/.test(e.benchmark_ids_used) ? String(e.benchmark_ids_used).split(":")[0].trim() : null;
  return `  (${i + 1}, ${q(e.household_size)}, ${q(e.level)}, ${num(e.total_per_year)}, ${num(e.total_per_month)}, ${num(e.total_per_day)}, ${q(e.one_time_costs_listed_separately)}, ${qa(used)}, ${q(note)})`;
});
const cf = W.Conflicts_Log.map((c, i) => `  (${i + 1}, ${q(c.benchmark_id)}, ${q(c.value_a)}, ${q(c.source_a)}, ${q(c.value_b)}, ${q(c.source_b)}, ${q(c.note)})`);
const ss = W.Sources.map((s) => `  (${q(s.source_id)}, ${q(s.title)}, ${q(s.full_url || s["full URL"])}, ${q(s.type)}, ${qd(s.date_accessed)}, ${q(s.source_date)})`);
if (fail.length) { console.error("Workbook checks failed:\n  " + fail.join("\n  ")); process.exit(1); }

writeFileSync(outPath, `-- Human Mirror database #3: Milwaukee Cost-of-Living Benchmarks, data. GENERATED by tools/cost-benchmarks-import.mjs from the
-- ${version} workbook (research date 11/13/2026); edit the workbook and run the tool again, never this file by hand.
-- ${rows.length} benchmarks, ${ex.length} Daily Number examples, ${cf.length} conflicts, ${ss.length} sources. Checked by the tool: ids unique,
-- categories and levels valid, every source_id exists, per-month and per-day figures match the yearly figure, every example adds up.
-- Reference data: this replaces all rows (nothing here is edited by the office).

delete from mirror.cost_benchmark_conflicts;
delete from mirror.cost_benchmark_examples;
delete from mirror.cost_benchmarks;
delete from mirror.cost_benchmark_sources;

insert into mirror.cost_benchmark_sources (source_id, title, url, source_type, date_accessed, source_date) values
${ss.join(",\n")};

insert into mirror.cost_benchmarks (benchmark_id, category, item, short_label, level, household_size, amount_as_published, unit, frequency,
  one_time_amount, per_year, per_month, per_day, formula, geography, as_of_date, poverty_premium, cheaper_alternative, verification_status,
  source_ids, sort, import_version) values
${rows.join(",\n")};

insert into mirror.cost_benchmark_examples (id, household_size, level, total_per_year, total_per_month, total_per_day, one_time_note, benchmark_ids, note) values
${ex.join(",\n")};

insert into mirror.cost_benchmark_conflicts (id, benchmark_id, value_a, source_a, value_b, source_b, note) values
${cf.join(",\n")};
`);
console.log(`Wrote ${outPath}: ${rows.length} benchmarks, ${ex.length} examples, ${cf.length} conflicts, ${ss.length} sources`);
