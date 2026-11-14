// T8.5: append the appointments/notes block to workspace-person.js and add the DIMENSIONS import (one-off; not committed)
import fs from "node:fs";
const f = "site/mirror/assets/workspace-person.js";
const block = fs.readFileSync(process.argv[2], "utf8");
let s = fs.readFileSync(f, "utf8");
if (s.includes("export async function appointmentsBox")) { console.error("already added"); process.exit(1); }
const a = 'import { progressBox } from "/mirror/assets/progress-page.js?v=20261113b";';
if (!s.includes(a)) { console.error("missing import"); process.exit(1); }
s = s.replace(a, a + '\nimport { DIMENSIONS } from "/mirror/assets/dimensions.js?v=20261113a";');
s = s.replace("// (goals, steps, milestones with the confirm button), progress (counts, never a score).",
  "// (goals, steps, milestones with the confirm button), progress (counts, never a score); T8.4 services; T8.5 appointments and contact notes.");
s = s.trimEnd() + "\n" + block;
fs.writeFileSync(f, s);
console.log("ok");
