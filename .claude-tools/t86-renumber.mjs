// T8.6: my decision is D-37 (lease-30's TN.1 took D-36 first). Replace only in my own T8.6 text. (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
edit("docs/human-mirror/DECISIONS.md", [["| D-36 | **Benefits applications for organizations (T8.6", "| D-37 | **Benefits applications for organizations (T8.6"]]);
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["(migration 20261119560000, t86 6/6, D-36 DEFAULT)", "(migration 20261119560000, t86 6/6, D-37 DEFAULT)"],
  ["Number links back so they are kept. No new tables. D-36 DEFAULT for Stephen to confirm.", "Number links back so they are kept. No new tables. D-37 DEFAULT for Stephen to confirm."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [["(migration 20261119560000, t86 6/6, D-36)", "(migration 20261119560000, t86 6/6, D-37)"]]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [["(D-34, D-35, D-36 DEFAULT to confirm); next T8.7", "(D-34, D-35, D-37 DEFAULT to confirm); next T8.7"]]);
edit("docs/human-mirror/DATABASE_DESIGN.md", [["mirror_benefit_dates (T8.6, D-36)", "mirror_benefit_dates (T8.6, D-37)"]]);
edit("supabase/migrations/20261119560000_mirror_benefit_applications.sql", [["the person removes their own records (D-36).", "the person removes their own records (D-37)."]]);
edit("tools/mirror-checks/t86-benefits-check.sql", [["benefits applications for the organization (D-36).", "benefits applications for the organization (D-37)."]]);
edit("site/mirror/assets/workspace-person.js", [["T8.6 benefits applications (D-36)", "T8.6 benefits applications (D-37)"]]);
