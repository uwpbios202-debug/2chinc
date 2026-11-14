// Builds supabase/migrations/20261119284000_mirror_refusals_kept.sql from the header and the LIVE mirror.allowed body,
// replacing exactly the three 'refused' audit calls with mirror.audit_refused(...).
import fs from "node:fs";
const [head, live, out] = process.argv.slice(2);
let b = fs.readFileSync(live, "utf8");
let n = 0;
b = b.replace(/perform mirror\.audit\(([^;]*?), 'refused', ([^;]*?)\);/g, (_m, a, c) => { n++; return `perform mirror.audit_refused(${a}, ${c});`; });
if (n !== 3) throw new Error("expected 3 replacements, got " + n);
b = b.split("$function$").join("$gate$") + ";\n";
fs.writeFileSync(out, fs.readFileSync(head, "utf8") + b);
console.log("replacements", n);
