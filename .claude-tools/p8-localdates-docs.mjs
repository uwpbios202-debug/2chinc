// Docs for the Milwaukee-date fix (migration 20261119590000). (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
let k = fs.readFileSync("docs/human-mirror/KNOWN_ISSUES.md", "utf8");
const a = k.split("\n").find((l) => l.startsWith("| P5-04 |"));
if (!a) { console.error("no P5-04"); process.exit(1); }
k = k.replace(a, a + "\n| P8-01 | Found 11/13/2026 by check t88 at 8:30 pm Central: the database runs in UTC, so every evening (after 6 pm, 7 pm in summer) current_date and the defaults of milestones.achieved_on, service_enrollments.started_on and inventory_given.given_on gave tomorrow's date. Records made in the evening fell outside reports and counts ending today; ended-on dates, milestone dates and \"this week\" were a day off. Fixed 11/13/2026: migration 20261119590000 runs the 20 Mirror functions that use the date on America/Chicago (a per-function setting; the rest of the database is unchanged; no data rewritten). 21 checks pass with it (t63 now dates its milestone with Milwaukee's day). | Fixed 11/13/2026 |");
fs.writeFileSync("docs/human-mirror/KNOWN_ISSUES.md", k); console.log("ok KNOWN_ISSUES");
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["- Phase 8 is built (T8.1-T8.8). Open: P2-08 admin pages (teams, roles, consent, email, data, platform audit view); Guided Tour (deferred, D-28).",
   "- Phase 8 is built (T8.1-T8.8). Open: P2-08 admin pages (teams, roles, consent, email, data, platform audit view); Guided Tour (deferred, D-28).\n" +
   "- Went live with lease-30's TN.3 deploy (4dce75e); t88 on live then failed 2 parts in the evening: P8-01, the UTC date. Fixed by migration\n" +
   "  20261119590000_mirror_local_dates.sql (20 Mirror functions run on America/Chicago). With it: t88, t87, t86, t85, t84, t83, t82, t81, t64,\n" +
   "  t63 (its milestone now dated with Milwaukee's day), t63b, t61, t25, t36, p2-fix01, p2-fix02, tn2 all pass (0 failed parts)."],
]);
