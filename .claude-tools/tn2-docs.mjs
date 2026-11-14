import fs from "node:fs";
const ed = (f, a, b) => { let s = fs.readFileSync(f, "utf8"); if (s.split(a).length !== 2) { console.log("MISS", f, a.slice(0, 60)); return; } fs.writeFileSync(f, s.replace(a, b)); console.log("ok", f); };
ed("docs/human-mirror/DECISIONS.md", "(g) no email. Table nav_whole_consents (migration 20261119610000). | DEFAULT (confirm) |",
  "(g) no email; (h) added by Claude at Stephen's request to choose the best (11/13/2026): once the person has their own Mirror sign-in (an email on their Mirror), they change sharing themselves in their Mirror Settings and the Navigator screen only shows it, so the Navigator side never overrides the person; without a sign-in, a new signing on the Navigator screen is copied into the Mirror again; withdrawing the housing consent revokes the Navigator organization's sharing and ends its work with the Mirror, and the Mirror stays the person's. Table nav_whole_consents (migrations 20261119610000, 20261119620000). | DECIDED 11/13/2026 (Stephen: \"make the best choice for our system\") |");
ed("docs/human-mirror/MASTER_ROADMAP.md", "Deps: T2.1, T2.6, T3.4.",
  "Deps: T2.1, T2.6, T3.4. Status: BUILT + LIVE 11/13/2026 (migration 20261119620000, check tn2 6/6): nav_referrals.mirror_individual_id; mirror.navigator_org makes the Navigator business's organization on first use (Navigator its admin); \"Start their Mirror\" on the person's file (/navigator/ and /staff/navigators/): invitation by email, or without email filled in together; an existing Mirror is linked, never overwritten; sharing beyond housing copied; \"Open their Mirror\" when active; withdrawing the housing consent revokes sharing and ends the work (D-36 DECIDED).");
ed("docs/human-mirror/NAVIGATOR.md", "the Mirror holds the whole person, the Navigator file keeps the housing work. |",
  "the Mirror holds the whole person, the Navigator file keeps the housing work. BUILT 11/13/2026 (migration 20261119620000): \"Start their Mirror\" and \"Open their Mirror\" on the person's file. |");
ed("docs/human-mirror/DATABASE_DESIGN.md", "| nav_whole_consents (public) |",
  "| nav_referrals.mirror_individual_id (public) | -> mirror.individuals (on delete set null) | A Navigator person's Human Mirror (TN.2, migration 20261119620000); the Navigator business is a Mirror organization (mirror.navigator_org). |\n| nav_whole_consents (public) |");
ed("docs/BUG-CHECK-ROTATION.md", "/navigator/ and /staff/navigators/ load nav-common.js?v=20261113a.",
  "/navigator/ and /staff/navigators/ load nav-common.js?v=20261113b. TN.2 (migration 20261119620000): 0 nav_referrals with a mirror_individual_id that are samples; 0 linked people whose housing consent is withdrawn while their Navigator organization link is not ended or still has unrevoked consents; every Navigator organization (kind navigator) has its Navigator as an active org_admin member (counts only); tn2 still 6/6 (rolled back).");
let s = fs.readFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", "utf8");
s = s.trimEnd() + `

### 11/13/2026 — Phase N step 19, TN.2: Navigator person = Mirror individual (Stephen: "go and D-36 (please make the best choice for our system)")
- D-36 DECIDED: Stephen's defaults kept, plus (h): once the person has their own Mirror sign-in they change sharing in their Mirror Settings and
  the Navigator screen only shows it; withdrawing the housing consent revokes the Navigator organization's sharing and ends its work.
- Migration 20261119620000_nav_person_mirror.sql: nav_referrals.mirror_individual_id; mirror.navigator_org (finds or makes the Navigator business's
  organization, the Navigator its admin); nav_mirror_start (their Navigator or the office; after the housing consent; never samples; the person's
  yes ticked; with email = invitation, without = active and filled in together; an existing Mirror by the same email is linked, never
  overwritten; sharing beyond housing copied); nav_whole_consent / nav_whole_consent_save / the withdraw trigger updated for D-36 (h). No email.
- Page: on the person's file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/ (nav-common.js ?v=20261113b):
  "Start their Mirror", then the Mirror's status and "Open their Mirror" (https://2ndchinc.org/mirror/workspace/person/).
- Checks: tn2 6/6 and tn1 6/6 rolled back with the migration; all 32 Mirror checks pass (0 failed). 0 real Navigator people today.
`;
fs.writeFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", s + "\n"); console.log("ok status");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("19.   TN.2 Navigator person", "19.   [DONE 11/13/2026, migration 20261119620000] TN.2 Navigator person"); fs.writeFileSync(h, t); console.log("ticked");
