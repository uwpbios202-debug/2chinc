import fs from "node:fs";
const ed = (f, a, b) => { let s = fs.readFileSync(f, "utf8"); if (!s.includes(a)) { console.log("MISS", f); return; } fs.writeFileSync(f, s.replace(a, b)); console.log("ok", f); };
ed("docs/human-mirror/KNOWN_ISSUES.md", "| P2-11 | No authenticator reset for coordinators outside 2nd Chance. | Open |",
  "| P2-11 | No authenticator reset for coordinators outside 2nd Chance. | FIXED 11/13/2026 (migration 20261119600000, check p211 6/6): Reset on https://2ndchinc.org/mirror/admin/ members list. An organization's admin resets plain Mirror sign-ins of their own members; 2nd Chance platform admins reset anyone except portal admins. Confirm identity by phone or in person + reason; signs out everywhere; organization audit log; 5 a day. |");
let s = fs.readFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", "utf8");
s = s.trimEnd() + `

### 11/13/2026 — Phase N step 17, P2-11: authenticator reset (Stephen: "go to the next in your build")
- Migration 20261119600000_mirror_authenticator_reset.sql: mirror.authenticator_reset_refusal (who may reset whom), mirror_admin_authenticators
  (each member: authenticator set up or not, may this admin reset it, last reset), mirror_admin_authenticator_reset (removes the person's
  authenticator factors and signs them out on every device; identity confirmed by phone or in person + reason required; 5 a day per admin;
  organization audit log action authenticator_reset). No email is sent. No new table.
- Rules: an organization's admin may reset only a plain Mirror sign-in of their own members (not 2nd Chance admin, office or field staff, leasing
  agents, Housing Navigators, 2nd Chance members or platform admins, nor someone in another organization); a 2nd Chance platform admin may reset
  anyone except a portal admin; nobody resets their own.
- Page: https://2ndchinc.org/mirror/admin/ members table has an Authenticator column with Reset (form: why + "I confirmed it is really them").
- Checks: p211 6/6 rolled back on live; all 32 Mirror checks pass with the migration (0 failed).
`;
fs.writeFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", s + "\n"); console.log("ok status");
