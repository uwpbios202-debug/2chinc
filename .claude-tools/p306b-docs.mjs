// Marks P3-06b done in KNOWN_ISSUES.md.
import fs from "node:fs";
const f = "docs/human-mirror/KNOWN_ISSUES.md";
let s = fs.readFileSync(f, "utf8");
const i = s.indexOf("| P3-06b |");
if (i < 0) throw new Error("P3-06b row not found");
const e = s.indexOf("\n", i);
s = s.slice(0, i) + "| P3-06b | Fix 6, screen part: an answer given to an earlier wording is flagged on the question screen and in the list; Earlier answers shows each answer with the choices of its own wording and that wording when it differs. Migration 20261119286000 (current_answers.question_version, mirror_set_get version + reworded), commit 9e19aa9, live 11/13. Versions bumped only along Phase 3's chain (engine ?v=20261113k in reflection-page.js; reflection-page.js ?v=20261113k in its 25 pages). daily-number-page.js, functional-page.js and workspace/person still import the engine at ?v=20261113j (same file; they get it once the 4-hour browser cache expires, or at their owners' next bump). | DONE 11/13 |" + s.slice(e);
fs.writeFileSync(f, s);
console.log("updated");
