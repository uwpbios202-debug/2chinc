// Doc edits for goal suggestions from the Vision reflection (Stephen 11/13/2026 "YES"). Each replace must match exactly once.
import fs from "node:fs";
const edits = [
  ["docs/human-mirror/MASTER_ROADMAP.md",
   "Not yet: the coordinator's view (Phase 8), suggestions from the vision reflection.",
   "Goal suggestions from the Vision reflection built + live 11/13/2026 (Stephen: YES; migration 20261119366000, check t63b 4/4). Not yet: the coordinator's view (Phase 8)."],
  ["docs/human-mirror/DEVELOPMENT_STATUS.md",
   "Open question for Stephen: goal suggestions from the vision reflection. |",
   "Goal suggestions from the Vision reflection built 11/13 (Stephen: YES; migration 20261119366000, t63b 4/4). |"],
  ["docs/human-mirror/DEVELOPMENT_STATUS.md",
   "- Open: ask Stephen whether goals should get suggestions from the vision reflection (handoff step 3; no build without his go). Guided Tour (D-28).",
   "- Step 3: Stephen answered YES (11/13/2026); built the same day, see the next entry. Guided Tour (D-28)."],
  ["docs/human-mirror/NEXT_ACTIONS.md",
   "   Waiting on Stephen: goal suggestions from the vision reflection (build only on his go). Also open:",
   "   Goal suggestions from the Vision reflection built 11/13 (Stephen: YES). Also open:"],
  ["docs/BUG-CHECK-ROTATION.md",
   "P5-02: Settings' download includes `living`.",
   "P5-02: Settings' download includes `living`. Goal suggestions (11/13/2026, migration 20261119366000): `mirror.goal_suggestion_dismissals` has row security and no anon/authenticated grants; t63b still 4/4 (rolled back); 0 goals with `from_key` whose category differs from their area's topic (count only)."],
];
for (const [f, a, b] of edits) {
  const t = fs.readFileSync(f, "utf8");
  const k = t.split(a).length - 1;
  if (k !== 1) { console.log("SKIP (" + k + " matches): " + f + " :: " + a.slice(0, 60)); continue; }
  fs.writeFileSync(f, t.replace(a, () => b));
  console.log("ok " + f);
}
