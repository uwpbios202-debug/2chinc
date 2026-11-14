// T6.3 doc updates: roadmap, sitemap, decision D-29, status entry, bug-check segment 12. Each replacement must hit exactly once.
import fs from "node:fs";
const edit = (file, pairs) => {
  let t = fs.readFileSync(file, "utf8");
  for (const [a, b] of pairs) {
    const n = t.split(a).length - 1;
    if (n !== 1) throw new Error(`${file}: expected 1 match, got ${n}: ${a.slice(0, 60)}`);
    t = t.replace(a, b);
  }
  fs.writeFileSync(file, t);
  console.log("ok", file);
};
const add = (file, after, text) => edit(file, [[after, after + text]]);

edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["**T6.2 Strengths inventory** (S).", "**T6.2 Strengths inventory** (S). Status: BUILT + LIVE 11/13/2026 (commit 3760df7, migration 20261119330000, page /mirror/my-mirror/my-strengths/, suggestions from answers, check t62)."],
  ["**T6.3 Goals, plans, action items, milestones** (M) — journey stages 1-6 as labels, not deadlines.",
   "**T6.3 Goals, plans, action items, milestones** (M) — journey stages 1-6 as labels, not deadlines. Status: BUILT 11/13/2026 (migration 20261119331000, pages /mirror/my-mirror/plan/, actions/, milestones/, check t63; no action_plans table, D-29). Not yet: the coordinator's view (Phase 8), suggestions from the vision reflection."],
]);
add("docs/human-mirror/SITEMAP.md",
  "| my-needs/ | My needs: needs inventory, each need its own record, followed identified -> verified (T6.1; built 11/13/2026). The needs/ reflection stays the questions. | 6 |",
  "\n| my-strengths/ | My strengths: skills, talents, experience, papers and training, languages, interests, people in my corner; suggestions from answers (T6.2; built 11/13/2026). The strengths/ reflection stays the questions. | 6 |");
edit("docs/human-mirror/SITEMAP.md", [
  ["| plan/ | Personal development plan: goals by stage, chosen by the person | 6", "| plan/ | Personal development plan: goals by stage, chosen by the person (T6.3; built 11/13/2026) | 6"],
  ["| actions/ | Things I need to do (mine and what others are doing for me) | 6", "| actions/ | Things I need to do (mine and what others are doing for me) (T6.3; built 11/13/2026) | 6"],
  ["| milestones/ | My accomplishments | 6 |", "| milestones/ | My accomplishments (T6.3; built 11/13/2026) | 6 |"],
]);
{
  const f = "docs/human-mirror/DECISIONS.md";
  const lines = fs.readFileSync(f, "utf8").split("\n");
  const i = lines.findIndex((l) => l.startsWith("| D-28 |"));
  if (i < 0 || lines.some((l) => l.startsWith("| D-29 |"))) throw new Error("D-28 missing or D-29 taken");
  lines.splice(i + 1, 0, "| D-29 | Goals and plan (T6.3, Phase 6, 11/13/2026), chosen by Claude for Stephen to confirm: (1) the six journey stages (Mirror1 Part 3) are an optional LABEL on a goal; nothing checks order or time, several run at once; a date is the person's own \"hope to by\", never enforced. (2) The \"plan\" is the person's goals by stage; no separate action_plans table (DATABASE_DESIGN listed one): a step belongs to one goal, one need, or neither. (3) A coordinator with \"see and change\" for the topic may add and update goals, steps and milestones (marked as theirs), but only the person removes them. (4) Reaching a goal adds a milestone by itself; an organization may confirm a milestone (same rule as D-27); changing a confirmed milestone's words or date takes the confirmation off. (5) No \"hidden\" count for anyone but the person (T6.1 report finding 1). | Open for Stephen |");
  fs.writeFileSync(f, lines.join("\n"));
  console.log("ok", f);
}
fs.appendFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", `
### 11/13/2026 — T6.1 examined; Phase 6 T6.3 goals, steps, milestones (migration 20261119331000)
- Stephen: "Before you start T6.3 examine and report on T6.1. After the report begin T6.3."
- T6.1 report (read-only + t61 rolled back on live, 9/9): database live (320000, applied by Stephen's db push, which also put the uncommitted
  269500 and 345000 live; their owners were told). Page committed (e802344) but not yet deployed when examined. Findings for Stephen:
  (1) coordinators get a count of hidden private needs (also in T6.2 strengths); (2) a need can never be removed, only "no longer needed";
  (3) no suggestions from answers already given; (4) D-27 waits; (5) a coordinator's word changes are not in the need's history;
  (6) /needs/ vs /my-needs/ names; (7) bug check did not cover Phase 6 (now added to segment 12).
- T6.3 migration 331000: mirror.goals (area, stage 1-6 label or none, optional hope-by date, status active/paused/achieved/let_go),
  mirror.action_items (for one goal, one need or neither; me or a named helper; to do/done/not doing; takes the goal's or need's topic),
  mirror.milestones (reaching a goal adds one; organizations may confirm; editing words/date removes the confirmation). Service_role only,
  row security on, no bulk emptying, same-person triggers. Functions: mirror_plan, mirror_goal_save, mirror_action_save,
  mirror_milestone_save, mirror_milestone_confirm, mirror_plan_delete (person only), mirror_my_export_plan. Decisions in D-29 (open).
- Pages /mirror/my-mirror/plan/ (goals by stage with their steps), actions/ (mine / others doing for me / done / not doing), milestones/;
  one module site/mirror/assets/plan-page.js. My Mirror link. Settings download and printable copy now include strengths (T6.2 open item)
  and goals, steps and milestones.
- Checks: t63 6/6 on live, rolled back. The three pages driven headless in Chrome with a stubbed client (add, refuse empty, step for a goal,
  mark done, reached, edit, remove; steps with a helper and for a need; milestones add/edit/remove): no script errors, no duplicate ids.
`);
add("docs/BUG-CHECK-ROTATION.md",
  "https://2ndchinc.org/mirror/my-mirror/daily-number/ and its plan/, what-if/, benefits/, household/ pages return 200 and all 13 pages load the same daily-number-page.js version.",
  " Mirror Phase 6 (11/13/2026, migrations 20261119320000, 330000, 331000): needs, need_events, strengths, strength_dismissals, goals, action_items, milestones have row security and no anon/authenticated/PUBLIC grants; 0 action_items or milestones linked to another person's goal or need, 0 goals with status achieved and no achieved_on (counts only; never read or quote the records); t61, t62, t63 still pass (rolled back); https://2ndchinc.org/mirror/my-mirror/my-needs/, my-strengths/, plan/, actions/, milestones/ return 200.");
