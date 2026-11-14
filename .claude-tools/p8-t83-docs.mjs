// T8.3 doc updates (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) {
    if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 80)); process.exit(1); }
    s = s.replace(a, b);
  }
  fs.writeFileSync(f, s);
  console.log("ok " + f);
};
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["| 8 Organization workspace | IN PROGRESS (2 of 8) |", "| 8 Organization workspace | IN PROGRESS (3 of 8) |"],
  ["(migration 20261119510000, t82 5/5). Next: T8.3 assessments with the person. Guided Tour (deferred, D-28). |",
   "(migration 20261119510000, t82 5/5). T8.3 assessments with the person (review page, per-set \"last together\") built and live 11/13 (migration 20261119530000, t83 6/6). Next: T8.4 services and enrollments. Guided Tour (deferred, D-28). |"],
  ["- Not yet: coordinators adding goals/steps from the overview (they can on the person's pages only through the person); reports leaving out\n  safety-mode records (T8.8).",
   "- Not yet: coordinators adding goals/steps from the overview (they can on the person's pages only through the person); reports leaving out\n  safety-mode records (T8.8).\n\n" +
   "### 11/13/2026 — Phase 8 T8.3: assessments with the person (Stephen: \"go to the next task in building the mirror\")\n" +
   "- Going over questions with the person already worked (one-person overview, \"Their Mirror\": mirror_answer_save with p_individual, the\n" +
   "  person sees \"by your coordinator\"). T8.3 adds the review. Migration 20261119530000_mirror_assessments_with_person.sql:\n" +
   "  public.mirror_assessments_review(org, individual) (coordinators with the authenticator; active, known people only): per person or per\n" +
   "  question set, counts and dates only: answers, asked for help, saved with you (still their answer), last time together, days together,\n" +
   "  changed or added by them since. Never answer words, never earlier answers (person only, 20261119271000); topics they keep private are\n" +
   "  not counted (a set only says some questions are private); private topics counted are logged as looks ('workspace_assessments'). No new tables.\n" +
   "- Pages: new https://2ndchinc.org/mirror/workspace/assessments/ (\"Questions together\", linked from the dashboard); on\n" +
   "  /mirror/workspace/person/ each question-set card shows last together / changed since / asked for help, with a how-to line.\n" +
   "- Checks: t83 6/6 rolled back on live. html-validate and module syntax ok on the 3 touched pages.\n" +
   "- Not yet: a set marked \"finished\" together (assessments.completed_at is never set; one assessment row per person and set)."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["**T8.3 Assessments with the person** (S).", "**T8.3 Assessments with the person** (S) — Status: DONE 11/13/2026 (migration 20261119530000, t83 6/6; /mirror/workspace/assessments/)."],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["T8.1 + P2-07 and T8.2 + P2-06 done 11/13; next T8.3 assessments with the person (S).",
   "T8.1 + P2-07, T8.2 + P2-06 and T8.3 done 11/13; next T8.4 services and enrollments (S)."],
]);
edit("docs/human-mirror/SITEMAP.md", [
  ["| assessments/ | Conduct or review assessments with the person | 8 |",
   "| assessments/ | Review the questions gone over with each person (counts and dates; going over them is on person/) | 8 (LIVE 11/13) |"],
]);
edit("docs/BUG-CHECK-ROTATION.md", [
  ["/mirror/workspace/person/ and /mirror/assets/workspace-person.js return 200.",
   "/mirror/workspace/person/ and /mirror/assets/workspace-person.js return 200. T8.3 (11/13/2026, migration 20261119530000): mirror_assessments_review is security definer with a fixed search_path and not executable by anon; mirror.assess_review_sets not executable by authenticated; t83 still 6/6 (rolled back); https://2ndchinc.org/mirror/workspace/assessments/ returns 200."],
]);
