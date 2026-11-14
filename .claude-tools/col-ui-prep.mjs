// LOCAL CHECK ONLY: builds a stub client with the benchmark rows a person would get, and a driver for the stability page.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { readWorkbook } from "../tools/lib/xlsx.mjs";
const W = readWorkbook("Issues and fixes/Databases_TheMirror/Milwaukee_Cost_of_Living_Benchmarks_use.xlsx");
const n = (v) => (v == null ? null : Number(v));
const rows = W.Benchmarks.filter((b) => /^Verified/.test(b.verification_status) && b.amount_as_published != null).map((b) => ({ id: b.benchmark_id, category: b.category, item: b.item,
  label: b.item.split(/ \(|\. |:/)[0], level: b.level, household: b.household_size, amount: n(b.amount_as_published), unit: b.unit, frequency: b.frequency, one_time: n(b.one_time_amount),
  per_month: n(b.per_month), per_day: n(b.per_day), as_of: b.as_of_date, geography: b.geography, poverty_premium: /^yes/i.test(b.poverty_premium || ""), cheaper: b.cheaper_alternative,
  status: b.verification_status, sources: String(b.source_ids || "").split(";").map((s) => s.trim()).filter(Boolean) }));
const sources = Object.fromEntries(W.Sources.map((s) => [s.source_id, { title: s.title, url: s.full_url }]));
const B = { version: "v0.3", office: false, rows, sources, examples: [], conflicts: [] };
mkdirSync("site/mirror/_col", { recursive: true });
let stub = readFileSync(".claude-tools/dn-stub-client.js", "utf8").replace('if (fn === "mirror_dn_get") return get();', 'if (fn === "mirror_cost_benchmarks") return ' + JSON.stringify(B) + ';\n  if (fn === "mirror_dn_get") return { ...get(), household_size: 1 };');
writeFileSync("site/mirror/_col/stub-client.js", stub);
writeFileSync("site/mirror/_col/daily-number-page.js", readFileSync("site/mirror/assets/daily-number-page.js", "utf8").replace(/\/mirror\/assets\/mirror-client\.js\?v=[0-9a-z]+/, "/mirror/_col/stub-client.js"));
const html = readFileSync("site/mirror/my-mirror/daily-number/stability/index.html", "utf8")
  .replace(/\/mirror\/assets\/daily-number-page\.js\?v=[0-9a-z]+/, "/mirror/_col/daily-number-page.js")
  .replace("</body>", `<script type="module">
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const out = []; await wait(2500); try {
const d = document.querySelector("#dnBench details"); out.push("panel: " + (d ? d.querySelector("summary").textContent : "MISSING"));
if (d) { d.open = true; out.push("rows (1 adult): " + d.querySelectorAll("tbody tr").length);
  const s = d.querySelector("#bnSize"); s.value = ""; s.dispatchEvent(new Event("change")); out.push("rows (all sizes): " + d.querySelectorAll("tbody tr").length);
  const c = d.querySelector("#bnCat"); c.value = "transportation"; c.dispatchEvent(new Event("change")); out.push("transportation rows: " + d.querySelectorAll("tbody tr").length);
  out.push("first: " + d.querySelector("tbody tr").textContent.split(/[ ]+/).join(" ").slice(0, 300));
  const b = d.querySelector("[data-bench]"); b.click(); await wait(300);
  out.push("form: cat=" + document.querySelector("#exCat").value + " label=" + document.querySelector("#exLabel").value + " amt=" + document.querySelector("#exAmt").value + " freq=" + document.querySelector("#exFreq").value + " note=" + document.querySelector("#exNote").value);
  out.push("daily line: " + document.querySelector("#exDaily").textContent);
  out.push("page wider than screen: " + (document.documentElement.scrollWidth > window.innerWidth)); } } catch (e) { out.push("ERROR " + e.message + " " + e.stack); }
const pre = document.createElement("pre"); pre.id = "COLOUT"; pre.textContent = out.join(String.fromCharCode(10)); document.body.append(pre);
</script></body>`);
writeFileSync("site/mirror/_col/stability.html", html);
console.log("prepared", rows.length, "rows");
