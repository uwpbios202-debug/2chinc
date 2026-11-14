// One-off doc edits for the Phase 6 finish (T6.4 + P5-02). Each replace must match exactly once.
import fs from "node:fs";
const edits = [
  ["docs/human-mirror/DEVELOPMENT_STATUS.md",
   "| 5 Functional and housing assessment | BUILT AND LIVE 11/13/2026 (not complete under Part 14) | P5-02 is no longer blocked: Settings already has the Phase 6 and T1.6 edits, but does not yet call mirror_my_export_living. T5.1",
   "| 5 Functional and housing assessment | BUILT AND LIVE 11/13/2026 (not complete under Part 14) | P5-02 fixed 11/13: Settings' download and printable copy include the Phase 5 records (mirror_my_export_living). T5.1"],
  ["docs/human-mirror/DEVELOPMENT_STATUS.md",
   "Open: P5-02 Settings download; Guided Tour (deferred, D-28). |",
   "Open: Guided Tour (deferred, D-28). |"],
  ["docs/human-mirror/DEVELOPMENT_STATUS.md",
   "| 6 Personal development | IN PROGRESS (3 of 4) | T6.1 needs, T6.2 strengths, T6.3 goals, steps and milestones built and live 11/13 (D-27, D-29, D-30 confirmed). Left: T6.4 progress page. Coordinators see none of it until Phase 8. |",
   "| 6 Personal development | BUILT AND LIVE 11/13/2026, Guided Tour pending (D-28) | T6.1 needs, T6.2 strengths, T6.3 goals, steps and milestones, T6.4 progress page (migration 20261119365000, /mirror/my-mirror/progress/, t64 5/5) built and live 11/13 (D-27, D-29, D-30 confirmed). Coordinators see none of it until Phase 8 (T8.2 reuses progressBox). Open question for Stephen: goal suggestions from the vision reflection. |"],
  ["docs/human-mirror/NEXT_ACTIONS.md",
   "1. **Now (11/13/2026): T6.4 progress page** (S): counts per life area (D-09, never a score) and history over time; it finishes Phase 6.\n   Also open: P5-02 (add the Phase 5 records to Settings' \"Download everything\"; no longer blocked), Phase 2 fixes P2-06 to P2-13 and P2-15,",
   "1. **Now (11/13/2026): Phase 7, T7.1 first** (link CHPMS to the Mirror). Phase 6 is built (T6.4 progress page and P5-02 done 11/13).\n   Waiting on Stephen: goal suggestions from the vision reflection (build only on his go). Also open: Phase 2 fixes P2-06 to P2-13 and P2-15,"],
  ["docs/human-mirror/NEXT_ACTIONS.md",
   "   Then Phase 7 (T7.1 first), Phase 8, Phase N, Phase 9, Phase 10.",
   "   Then Phase 8, Phase N, Phase 9, Phase 10."],
  ["docs/human-mirror/KNOWN_ISSUES.md",
   "Settings belongs to the Phase 3 session: merge the two there. | Open |",
   "Settings belongs to the Phase 3 session: merge the two there. Fixed 11/13/2026: Settings' download adds `living` (mirror_my_export_living) and the printable copy has \"Everyday activities and where I live\" (latest sitting, where I live, where I have lived). | Fixed 11/13/2026 |"],
  ["docs/human-mirror/MASTER_ROADMAP.md",
   "**T6.4 Progress page** (S) — counts per dimension (D-09), history over time.",
   "**T6.4 Progress page** (S) — counts per dimension (D-09), history over time. Status: BUILT + LIVE 11/13/2026 (migration 20261119365000 `mirror_progress`, page /mirror/my-mirror/progress/, progress-page.js, check t64 5/5 rolled back). Not yet: the coordinator's view (Phase 8, T8.2 reuses progressBox)."],
  ["docs/human-mirror/SITEMAP.md",
   "| milestones/ | My accomplishments (T6.3; built 11/13/2026) | 6 |",
   "| milestones/ | My accomplishments (T6.3; built 11/13/2026) | 6 |\n| progress/ | My progress: counts per area of life and per month, last 12 months; never a score (T6.4, D-09; built 11/13/2026) | 6 |"],
  ["docs/BUG-CHECK-ROTATION.md",
   "https://2ndchinc.org/mirror/my-mirror/my-needs/, my-strengths/, plan/, actions/, milestones/ return 200.",
   "https://2ndchinc.org/mirror/my-mirror/my-needs/, my-strengths/, plan/, actions/, milestones/ return 200. T6.4 (11/13/2026, migration 20261119365000): `public.mirror_progress` is security definer with a fixed search_path and not executable by anon; t64 still 5/5 (rolled back); https://2ndchinc.org/mirror/my-mirror/progress/ returns 200; the page shows counts only (no percent, score or rank). P5-02: Settings' download includes `living`."],
];
for (const [f, a, b] of edits) {
  const t = fs.readFileSync(f, "utf8");
  const k = t.split(a).length - 1;
  if (k !== 1) { console.log("SKIP (" + k + " matches): " + f + " :: " + a.slice(0, 60)); continue; }
  fs.writeFileSync(f, t.replace(a, () => b));
  console.log("ok " + f);
}
