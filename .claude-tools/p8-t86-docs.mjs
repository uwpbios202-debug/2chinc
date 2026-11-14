// T8.6 doc updates (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d36 = "| D-36 | **Benefits applications for organizations (T8.6, 11/13/2026).** Defaults chosen by Claude, for Stephen to confirm: (a) one record per benefit, the person's own (mirror.benefit_records from Phase 4, topic Money); no second table; (b) a coordinator sees a person's benefits only while the person shares Money with that organization, each look logged; adds and changes only with \"see and change\" for Money (mirror_dn_save), and the person sees who changed it last; (c) the workspace offers no remove: the person removes their own records; (d) the dashboard lists renewals due in the next 30 days or already passed (still active or appealing) and appeal deadlines in the next 30 days, only for people who share Money; (e) program names are free text with common Wisconsin programs suggested (FoodShare, BadgerCare Plus, SSI, SSDI, W-2, Wisconsin Shares, WIC, Section 8, public housing, WHEAP, Lifeline ...). Migration 20261119560000. | DEFAULT (confirm) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-35 | **Appointments and contact notes";
if (!dec.includes(anchor)) { console.error("no D-35 anchor"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec.slice(0, i) + d36 + dec.slice(i)); console.log("ok DECISIONS");
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["| 8 Organization workspace | IN PROGRESS (5 of 8) |", "| 8 Organization workspace | IN PROGRESS (6 of 8) |"],
  ["(migration 20261119550000, t85 7/7, D-35 DEFAULT). Next: T8.6 benefits applications.",
   "(migration 20261119550000, t85 7/7, D-35 DEFAULT). T8.6 benefits applications built and live 11/13 (migration 20261119560000, t86 6/6, D-36 DEFAULT). Next: T8.7 inventory of donated goods."],
  ["- Not yet: reminder emails (Phase 9, T9.2).",
   "- Not yet: reminder emails (Phase 9, T9.2).\n\n" +
   "### 11/13/2026 — Phase 8 T8.6: benefits applications (Stephen: \"go\")\n" +
   "- Built on the existing mirror.benefit_records (Phase 4: program, status, applied/approved/renewal/appeal-by/end dates; the person already\n" +
   "  sees renewal and appeal warnings). Migration 20261119560000_mirror_benefit_applications.sql: public.mirror_benefits (one person, topic\n" +
   "  Money shared with the organization, logged, who changed it last) and public.mirror_benefit_dates (dashboard: renewals due in 30 days or\n" +
   "  passed, appeal deadlines in 30 days, people who share Money only). Saving goes through mirror_dn_save; the form passes the person's Daily\n" +
   "  Number links back so they are kept. No new tables. D-36 DEFAULT for Stephen to confirm.\n" +
   "- Pages: Benefits and applications section on /mirror/workspace/person/ (workspace-person.js ?v=20261113d; Wisconsin program suggestions,\n" +
   "  renewal and appeal warnings, no remove); dashboard section \"Benefit renewals and appeal deadlines\".\n" +
   "- Checks: t86 6/6 rolled back on live (incl. the Daily Number link kept after a coordinator's change). html-validate and module syntax ok."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["**T8.6 Benefits applications** (S, renewal and appeal dates).", "**T8.6 Benefits applications** (S, renewal and appeal dates) — Status: DONE 11/13/2026 (migration 20261119560000, t86 6/6, D-36)."],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["T8.3, T8.4 and T8.5 done 11/13 (D-34, D-35 DEFAULT to confirm); next T8.6 benefits applications (S).",
   "T8.3 to T8.6 done 11/13 (D-34, D-35, D-36 DEFAULT to confirm); next T8.7 inventory of donated goods (M)."],
]);
edit("docs/human-mirror/DATABASE_DESIGN.md", [
  ["| benefit_applications | individual_id, program (snap, medicaid, ssi, ssdi, tanf, section8, public_housing, liheap, lifeline, wic, workforce, other), applied_on, status, decision_on, renewal_on, appeal_by | Mirror1 Part 5B. |",
   "| benefit_applications | not a separate table: mirror.benefit_records (Phase 4) holds program, kind, agency, status, applied_on, approved_on, renewal_on, appeal_by, ends_on | Mirror1 Part 5B. Organizations read it through mirror_benefits and the dashboard through mirror_benefit_dates (T8.6, D-36). |"],
]);
edit("docs/BUG-CHECK-ROTATION.md", [
  ["https://2ndchinc.org/mirror/my-mirror/appointments/ and https://2ndchinc.org/mirror/my-mirror/notes/ return 200.",
   "https://2ndchinc.org/mirror/my-mirror/appointments/ and https://2ndchinc.org/mirror/my-mirror/notes/ return 200. T8.6 (11/13/2026, migration 20261119560000): mirror_benefits and mirror_benefit_dates are security definer with a fixed search_path and not executable by anon; t86 still 6/6 (rolled back)."],
]);
