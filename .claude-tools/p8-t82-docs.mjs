// Doc edits for Phase 8 T8.2 (11/13/2026). Each replace must match exactly once.
import fs from "node:fs";
const edits = [
  ["docs/human-mirror/DEVELOPMENT_STATUS.md",
   "| 8 Organization workspace | IN PROGRESS (1 of 8) | T8.1 dashboard and people list + P2-07 (organization's own audit log) built and live 11/13 (migration 20261119500000, t81 6/6). Next: T8.2 one-person overview (with P2-06 safety banner).",
   "| 8 Organization workspace | IN PROGRESS (2 of 8) | T8.1 dashboard and people list + P2-07 (organization's own audit log) built and live 11/13 (migration 20261119500000, t81 6/6). T8.2 one-person overview + P2-06 safety note, T6.1 findings 5 and 6, milestone confirm button built and live 11/13 (migration 20261119510000, t82 5/5). Next: T8.3 assessments with the person."],
  ["docs/human-mirror/KNOWN_ISSUES.md", "| P2-06 | The safety flag is not used. | Open |",
   "| P2-06 | The safety flag is not used. Fixed 11/13/2026 with T8.2: a safety note on the coordinator's one-person overview and a \"Safety mode\" tag on the people list; Settings now says so. Leaving safety-mode records out of reports stays with T8.8. | Fixed 11/13/2026 |"],
  ["docs/human-mirror/MASTER_ROADMAP.md", "**T8.2 One-person overview** (M, consent-limited sections, safety banner).",
   "**T8.2 One-person overview** (M, consent-limited sections, safety banner). Status: BUILT + LIVE 11/13/2026 (migration 20261119510000; workspace-person.js on /mirror/workspace/person/: safety note P2-06, needs with status / confirm met / change the words (T6.1 finding 5: recorded in the need's own history), strengths, plan with the milestone confirm button, progress; list pages renamed \"My needs list\" / \"My strengths list\" with links to the questions (finding 6); check t82 5/5)."],
  ["docs/human-mirror/NEXT_ACTIONS.md", "T8.1 + P2-07 done 11/13; next T8.2 one-person overview (+ P2-06).",
   "T8.1 + P2-07 and T8.2 + P2-06 done 11/13; next T8.3 assessments with the person (S)."],
  ["docs/human-mirror/SITEMAP.md",
   "| people/ · people/new/ · people/view/?id= | People enrolled; add and invite; one-person overview (consent-limited sections) | 2 (new/invite) / 8 |",
   "| people/ · people/new/ · people/view/?id= | People enrolled; add and invite; one-person overview (consent-limited sections) | 2 (new/invite) / 8 |\n| person/?id=&org= | One-person overview: safety note, needs, plan, strengths, progress, what they share, their answers (T8.2, built 11/13/2026) | 8 |"],
  ["docs/BUG-CHECK-ROTATION.md", "https://2ndchinc.org/mirror/workspace/, people/, audit/ return 200.",
   "https://2ndchinc.org/mirror/workspace/, people/, audit/ return 200. T8.2 (11/13/2026, migration 20261119510000): t82 still 5/5 (rolled back); every need_events row with from_status = to_status was written by someone other than the person (by_role <> 'self'; count only); /mirror/workspace/person/ and /mirror/assets/workspace-person.js return 200."],
];
for (const [f, a, b] of edits) {
  const t = fs.readFileSync(f, "utf8");
  const k = t.split(a).length - 1;
  if (k !== 1) { console.log("SKIP (" + k + " matches): " + f); continue; }
  fs.writeFileSync(f, t.replace(a, () => b));
  console.log("ok " + f);
}
