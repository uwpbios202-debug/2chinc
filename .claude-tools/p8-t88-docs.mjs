// T8.8 doc updates (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d39 = "| D-39 | **Outcomes and reports (T8.8, 11/13/2026).** Defaults chosen by Claude, for Stephen to confirm: (a) one report per organization and period: counts only, no names, no person ids, no score of anyone (D-09); (b) coordinators and organization admins (authenticator); volunteers and other organizations no; (c) people in safety mode are left out of every count and the report says how many (P2-06); (d) only people the organization works or worked with in the period and knows; private topics counted only for people who share them now; the organization's own records follow their topic; corrections are not counted as contacts; (e) each run is written once to the organization's audit log without any person; (f) \"For sharing\" (on by default) shows 1 to 4 as \"fewer than 5\" on screen, in print and in the CSV. Function public.mirror_org_report (migration 20261119580000). | DEFAULT (confirm) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-38 | **Donated goods";
if (!dec.includes(anchor)) { console.error("no D-38 anchor"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec.slice(0, i) + d39 + dec.slice(i)); console.log("ok DECISIONS");
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["| 8 Organization workspace | IN PROGRESS (7 of 8) |", "| 8 Organization workspace | BUILT AND LIVE 11/13/2026 (8 of 8), Guided Tour pending (D-28) |"],
  ["t87 5/5, D-38 DEFAULT). Next: T8.8 outcomes and reports.",
   "t87 5/5, D-38 DEFAULT). T8.8 outcomes and reports built and live 11/13 (migration 20261119580000, t88 5/5, D-39 DEFAULT). Phase 8 open: P2-08 admin pages."],
  ["- Checks: t87 5/5 rolled back on live. html-validate and module syntax ok on the 5 touched pages and workspace-person.js.",
   "- Checks: t87 5/5 rolled back on live. html-validate and module syntax ok on the 5 touched pages and workspace-person.js.\n\n" +
   "### 11/13/2026 — Phase 8 T8.8: outcomes and reports (Stephen: \"go\"); Phase 8 built\n" +
   "- Migration 20261119580000_mirror_org_reports.sql: public.mirror_org_report(org, from, to): people, needs (noted, met, confirmed by you,\n" +
   "  open, by area), goals reached, steps done, milestones (confirmed by you), services, appointments, contacts (corrections not counted),\n" +
   "  referrals, benefits (Money shared only), questions gone over together, donated goods (to people, outside the Mirror, by kind). Counts only;\n" +
   "  safety-mode people left out and counted as left out (P2-06); private topics only where shared; each run in the organization's audit log.\n" +
   "  No new tables. D-39 DEFAULT for Stephen.\n" +
   "- Page: new https://2ndchinc.org/mirror/workspace/reports/ (\"Outcomes and reports\", from the dashboard): periods (this month, last month,\n" +
   "  this year, last year, last 12 months, chosen dates), \"For sharing\" (1-4 shown as \"fewer than 5\"), Print, CSV download.\n" +
   "- Checks: t88 5/5 rolled back on live (incl. no names or words in the report). html-validate and module syntax ok.\n" +
   "- Phase 8 is built (T8.1-T8.8). Open: P2-08 admin pages (teams, roles, consent, email, data, platform audit view); Guided Tour (deferred, D-28)."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["## Phase 8: Organization workspace (size L)", "## Phase 8: Organization workspace (size L) — BUILT AND LIVE 11/13/2026 (T8.1-T8.8; open: P2-08; Guided Tour (deferred, D-28))"],
  ["**T8.8 Outcomes and reports** (M, counts per organization; no person scores; safety-mode records excluded by name).",
   "**T8.8 Outcomes and reports** (M, counts per organization; no person scores; safety-mode records excluded by name) — Status: DONE 11/13/2026 (migration 20261119580000, t88 5/5, D-39; /mirror/workspace/reports/)."],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["T8.7 donated goods done 11/13 (D-38 DEFAULT); next T8.8 outcomes and reports (M).",
   "T8.7 donated goods and T8.8 reports done 11/13 (D-38, D-39 DEFAULT): Phase 8 built; next P2-08 admin pages (M)."],
]);
edit("docs/human-mirror/SITEMAP.md", [
  ["| outcomes/ · reports/ | Outcome measures and organization reports (counts, no single person score) | 8 |",
   "| reports/ | Outcomes and reports: counts per period, no names, no score of anyone; safety-mode people left out; \"for sharing\" hides 1-4; print and CSV (T8.8, D-39; built 11/13/2026; outcomes/ is part of it) | 8 |"],
]);
edit("docs/BUG-CHECK-ROTATION.md", [
  ["t87 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/inventory/ returns 200.",
   "t87 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/inventory/ returns 200. T8.8 (11/13/2026, migration 20261119580000): mirror_org_report is security definer with a fixed search_path and not executable by anon; t88 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/reports/ returns 200."],
]);
