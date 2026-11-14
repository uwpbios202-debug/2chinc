// Draft plan for the example person against a saved directory JSON (local check only). Usage: node listen-plan.mjs <dir.json>
import fs from "node:fs";
import { analyse, draftPlan } from "../site/mirror/assets/mirror-listen.js";
const raw = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const dir = raw[0].d;
const ex = JSON.parse(fs.readFileSync(new URL("./listen-example.json", import.meta.url), "utf8"));
const P = draftPlan(analyse(ex).filter((f) => !f.private), dir);
for (const s of P.steps) {
  console.log("## " + s.need.key + (s.more ? `  (+${s.more} more)` : ""));
  for (const x of s.suggestions) console.log("   - " + x.p.program_name + " / " + (x.p.org.dba || x.p.org.legal_name) + " [" + x.score + "] " + x.popHits.join(","));
}
