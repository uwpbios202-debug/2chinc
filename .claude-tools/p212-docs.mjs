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
both("docs/human-mirror/KNOWN_ISSUES.md", (s) => s.replace(/\| P2-12 \| Consent expiry cannot be set and there is no reminder\. \| Open \|/,
  "| P2-12 | Consent expiry cannot be set and there is no reminder. | FIXED 11/14/2026 (migration 20261119690000, check p212 5/5): the person sets or clears an end date per organization and topic in Settings; a coordinator records the date a person without a sign-in gave; the date is kept when the choice changes; both sides see it; a week before, the email \"Sharing ending soon\" (kind mirror_sharing, off until Stephen turns it on); the day after, the share stops. |"));
both("docs/human-mirror/DEVELOPMENT_STATUS.md", (s) => s.trimEnd() + `

### 11/14/2026 — Phase 9 step 26, P2-12: end dates for sharing, with a reminder (Stephen: "go")
- Migration 20261119690000_mirror_consent_end_dates.sql: mirror_my_consent_until (person), mirror_consent_record_until (coordinator, person without
  a sign-in), the end date carried over by mirror_my_consent_set and mirror_consent_record, shown by mirror_my_settings ('sharing_until') and
  mirror_consents_recorded ('until'); email kind mirror_sharing (7th kind, off until Stephen turns it on; neutral in safety mode) sent 7 days before
  by mirror.send_reminders (the mirror-reminders job, unchanged). Dates: tomorrow up to 5 years. mirror.allowed already stops a share after its date.
- Pages: Settings (https://2ndchinc.org/mirror/my-mirror/settings/) "Shared until" per topic with Save end date / No end date; the coordinator's
  "What they share" shows "until"; the record form takes an optional end date. /mirror/register/ phone number kept on one line (lease-6f's a11y pass).
- Checks: p212 5/5 rolled back; t91 updated for 7 kinds (5/5); t92 4/4; all Mirror checks pass with the migration (landlord-database check errors
  the same way without it).
` + "\n");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("26.   P2-12 Consent expiry", "26.   [DONE 11/14/2026, migration 20261119690000] P2-12 Consent expiry"); fs.writeFileSync(h, t); console.log("ticked");
