// Adds the Mirror Phase 6 line to bug-check segment 12 (exactly one match required).
import fs from "node:fs";
const f = "docs/BUG-CHECK-ROTATION.md";
const t = fs.readFileSync(f, "utf8");
const a = "the 8 `*_change_log` triggers exist, and t45 passes (rolled back).";
const n = t.split(a).length - 1;
if (n !== 1) throw new Error("match count " + n);
const add = " Mirror Phase 6 (11/13/2026, migrations 20261119320000, 330000, 331000): needs, need_events, strengths, strength_dismissals, goals, action_items, milestones have row security and no anon/authenticated/PUBLIC grants; 0 action_items or milestones linked to another person's goal or need, 0 goals with status achieved and no achieved_on (counts only; never read or quote the records); t61, t62, t63 still pass (rolled back); https://2ndchinc.org/mirror/my-mirror/my-needs/, my-strengths/, plan/, actions/, milestones/ return 200.";
fs.writeFileSync(f, t.replace(a, a + add));
console.log("ok");
