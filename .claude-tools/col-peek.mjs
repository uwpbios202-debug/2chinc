import { readFileSync } from "node:fs";
const src = readFileSync(".claude-tools/xlsx-peek.mjs", "utf8").split("for (const f of process.argv")[0];
const readWorkbook = new Function("readFileSync", "inflateRawSync", src.replace(/^import.*$/gm, "") + "; return readWorkbook;")(readFileSync, (await import("node:zlib")).inflateRawSync);
const W = readWorkbook(process.argv[2]);
for (const r of W.Benchmarks) console.log([r.benchmark_id, r.category, r.level, r.household_size, r.amount_as_published, r.unit, r.frequency, r.one_time_amount, r.per_month, r.geography, r.as_of_date, r.poverty_premium, r.verification_status, r.source_ids].join(" | ") + "\n    " + r.item.slice(0, 230) + (r.cheaper_alternative ? "\n    ALT: " + r.cheaper_alternative.slice(0, 150) : ""));
console.log(JSON.stringify(W.README, null, 0).slice(0, 4000));
console.log(JSON.stringify(W.Daily_Number_Examples));
console.log(JSON.stringify(W.Conflicts_Log).slice(0, 3000));
