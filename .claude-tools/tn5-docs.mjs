import fs from "node:fs";
const ed = (f, a, b) => { let s = fs.readFileSync(f, "utf8"); if (s.split(a).length !== 2) { console.log("MISS", f, a.slice(0, 60)); return; } fs.writeFileSync(f, s.replace(a, b)); console.log("ok", f); };
ed("docs/human-mirror/MASTER_ROADMAP.md", "Deps: T6.1 for the links (the earlier start has no deps).",
  "Deps: T6.1 for the links (the earlier start has no deps). Status: BUILT + LIVE 11/13/2026 (migration 20261119650000, check tn5 6/6): the plan starts once the housing consent is signed (\"Start check-ins\" on the file); recording one schedules the next; closing before move-in clears it; move-in adds the 90-day and 12-month reviews as before; retention pay unchanged; check-ins are linked to Mirror needs in the Mirror (https://2ndchinc.org/mirror/workspace/checkins/, authenticator and shared topics only). Reminder emails before move-in wait for Stephen. PHASE N BUILT.");
ed("docs/human-mirror/NAVIGATOR.md", "and follows the Mirror plan, not only the housing. |",
  "and follows the Mirror plan, not only the housing. BUILT 11/13/2026 (migration 20261119650000). |");
ed("docs/human-mirror/SITEMAP.md", "| referrals/?id=&org= | Referrals:",
  "| checkins/?id=&org= | Navigator check-ins with the person (from the first meeting), each linkable to one of their Mirror needs in a shared topic (TN.5; linked from \"Open their Mirror\" on the Navigator file; built 11/13/2026) | N |\n| referrals/?id=&org= | Referrals:");
ed("docs/human-mirror/DATABASE_DESIGN.md", "| nav_whole_consents (public) |",
  "| nav_followups.mirror_need_id (public) | -> mirror.needs (on delete set null) | A Navigator check-in linked to a Mirror need, set only in the Mirror (TN.5, migration 20261119650000). |\n| nav_whole_consents (public) |");
let s = fs.readFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", "utf8");
s = s.trimEnd() + `

### 11/13/2026 — Phase N step 22, TN.5: check-ins from the first meeting (Stephen: "go"). Phase N is built.
- Migration 20261119650000_nav_checkins_first_meeting.sql: nav_checkin_schedule works on any open file with a signed housing consent (was moved
  in only); trigger: recording a check-in before move-in schedules the next; trigger: closing before move-in clears the open check-in;
  nav_followups.mirror_need_id; mirror_nav_checkins / mirror_nav_checkin_link (Mirror gate: authenticator, the Navigator's own organization,
  needs in shared topics, "see and change" to link). nav_followup_save (retention pay) and nav_followup_reminders (emails) are unchanged.
- Pages: the file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/ (nav-common.js ?v=20261113d): "Start check-ins"
  before housing, check-ins recorded before housing (no rent box), "linked to a need in their Mirror"; new https://2ndchinc.org/mirror/workspace/checkins/.
- Open for Stephen: reminder emails for check-ins before move-in (new sends of the existing check-in reminder) wait for his OK.
- Checks: tn5 6/6 rolled back; all 32 Mirror checks, tn2 and tn4 pass with the migration.
`;
fs.writeFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", s + "\n"); console.log("ok status");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("22.   TN.5 Check-ins from the first meeting", "22.   [DONE 11/13/2026, migration 20261119650000] TN.5 Check-ins from the first meeting"); fs.writeFileSync(h, t); console.log("ticked");
