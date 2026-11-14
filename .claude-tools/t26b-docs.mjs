import fs from "node:fs";
import { execSync } from "node:child_process";
const both = (path, fn) => {
  const head = execSync(`git show HEAD:${path}`, { encoding: "utf8", maxBuffer: 64e6 });
  const work = fs.readFileSync(path, "utf8");
  const h2 = fn(head), w2 = fn(work);
  if (h2 === head || w2 === work) { console.log("MISS", path); process.exit(1); }
  fs.mkdirSync(".claude-tools/stage/" + path.split("/").slice(0, -1).join("/"), { recursive: true });
  fs.writeFileSync(".claude-tools/stage/" + path, h2); fs.writeFileSync(path, w2); console.log("ok", path);
};
const once = (a, b) => (s) => (s.split(a).length === 2 ? s.split(a).join(b) : s);
both("docs/human-mirror/DECISIONS.md", once("never the words. | DEFAULT (confirm) |", "never the words. | DECIDED 11/13/2026 (Stephen: \"D-42 yes\"; the invitation wording: \"it is perfect\") |"));
both("docs/human-mirror/MASTER_ROADMAP.md", once("Still to do: the invitation email (wording to Stephen first) and /mirror/register/.",
  "Second half BUILT + LIVE 11/13/2026 (migration 20261119670000, check t26b 5/5): the invitation email (wording approved by Stephen) goes out through mirror.email_queue for every way a person or member is invited (triggers), \"Send the invitation again\" on /mirror/workspace/people/ and /mirror/admin/ (once per 12 hours), and https://2ndchinc.org/mirror/register/ explains how to accept. Held until Stephen turns the invitation kinds on at https://2ndchinc.org/mirror/admin/email/. Also fixed: the 12-hour repeat guard counts only emails really queued, not held ones."));
both("docs/human-mirror/KNOWN_ISSUES.md", (s) => s.replace(/\| T2\.6 \| \/mirror\/register\/ \(accepting an invitation by link\) not built;[^\n]*\| Open \|/,
  "| T2.6 | /mirror/register/ (accepting an invitation by link) not built; invitation email waits for Phase 9 and Stephen's wording. | FIXED 11/13/2026 (migration 20261119670000): invitation email (approved wording, held until Stephen turns it on) and https://2ndchinc.org/mirror/register/. |"));
both("docs/human-mirror/SITEMAP.md", once("| /mirror/register/ | Invite acceptance (and self-registration if D-03 allows) | P | 2 |",
  "| /mirror/register/ | Invite acceptance: how to sign in with the invited email and accept or decline on My Mirror (T2.6, built 11/13/2026; no self-registration) | P | 9 |"));
both("docs/human-mirror/DEVELOPMENT_STATUS.md", (s) => s.trimEnd() + `

### 11/13/2026 — Phase 9 step 24, T2.6 second half: the invitation email and /mirror/register/ (Stephen: "D-42 yes", wording "perfect")
- Migration 20261119670000_mirror_invitation_email.sql: triggers on mirror.organization_individuals (status becomes invited, with an email) and
  mirror.organization_members (new or reactivated member) queue mirror_invite / mirror_staff_invite through mirror.email_queue; mirror_invitation_resend
  and mirror_member_invite_resend ("Send the invitation again"). mirror_person_add, mirror_admin_member_save and nav_mirror_start are not changed.
  Fix in mirror.email_queue: the 12-hour repeat guard counts only queued emails, not held ones. D-42 DECIDED.
- Pages: new https://2ndchinc.org/mirror/register/; "Send the invitation again" on https://2ndchinc.org/mirror/workspace/people/ (people waiting to
  accept) and https://2ndchinc.org/mirror/admin/ (members). Every kind is still off: nothing is sent until Stephen turns it on.
- Checks: t26b 5/5 and t91 5/5 rolled back with the migration; all Mirror checks pass (the landlord-database and p215 checks error the same way
  without it: another session's work in progress).
` + "\n");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("24.   T2.6 second half (S)", "24.   [DONE 11/13/2026, migration 20261119670000] T2.6 second half (S)"); fs.writeFileSync(h, t); console.log("ticked");
