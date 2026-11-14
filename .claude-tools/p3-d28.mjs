// Adds "Guided Tour (deferred, D-28)" to the Phase 3 open items in KNOWN_ISSUES.md.
import fs from "node:fs";
const f = "docs/human-mirror/KNOWN_ISSUES.md";
let s = fs.readFileSync(f, "utf8");
if (s.includes("| P3-GT |")) { console.log("already there"); process.exit(0); }
const i = s.indexOf("| P3-06b |");
if (i < 0) throw new Error("P3-06b row not found");
const row = "| P3-GT | Guided Tour (deferred, D-28): the signed-in Phase 3 checks wait for it: My Mirror, the 8 reflections, the 15 life areas and Settings (incl. the new \"Emails from the Mirror\" section) drawn with real data; hands-free with a real voice; Speak / Read aloud in Chrome, Firefox, Edge; computer, Android, iPhone; screen reader. Not asked for or scheduled until all phases are done. | Deferred (D-28) |\n";
s = s.slice(0, i) + row + s.slice(i);
fs.writeFileSync(f, s);
console.log("added");
