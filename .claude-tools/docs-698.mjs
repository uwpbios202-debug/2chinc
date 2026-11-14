import fs from "node:fs";
const ed = (p, a, b) => { const s = fs.readFileSync(p, "utf8"); if (!s.includes(a)) throw new Error(p + ": " + a.slice(0, 80)); fs.writeFileSync(p, s.replace(a, b)); };
const K = "docs/human-mirror/KNOWN_ISSUES.md";
ed(K, "11/14/2026: legal is working on it; we wait for them (D-46). |",
  "11/14/2026: legal is working on it; we wait for them (D-46). DONE 11/14/2026: legal's final text published at https://2ndchinc.org/mirror/privacy/ (Stephen confirmed the promises only 2nd Chance keeps: monthly log review, a lawyer for court orders and subpoenas, breach notice within 30 days, the board's closure promise, complaints answered in 14 days, HIPAA and Wis. Stat. 134.97 / 895.67 checked by counsel). The promises about how the Mirror works were built first (migration 20261119698000, D-47); backups sentence: removed automatically within 7 days. |");
const D = "docs/human-mirror/DECISIONS.md";
const L = fs.readFileSync(D, "utf8").split("\n"); const i = L.findIndex((l) => l.startsWith("| D-46 |"));
L.splice(i + 1, 0, "| D-47 | **Making the final privacy page true (11/14/2026, Stephen: \"build all 3 first\"; plain sign-in subject for everyone; backups \"within 7 days\"; the other promises confirmed).** (a) Hide now: the person (Settings), a coordinator of an organization they work with (People list: only when the person asks, in person or by phone, with a reason) or 2nd Chance (platform page, by email, after confirming it is them, optionally recording a deletion asked on the phone) hides the Mirror at once: every organization link ends, the person leaves every list and is unnamed in organization audit logs, nobody can restart, re-invite or re-add them; only the person shows it again (old links stay ended). A coordinator's hide never asks for deletion (no coordinator can get a Mirror deleted). Hiding and deletion are independent. (b) Adults only: a birth year making the person under 18 (this year minus birth year < 18) is refused wherever entered; birth year stays optional. (c) Change notice: the main admin sets it on https://2ndchinc.org/mirror/admin/platform/ (start date after today); every Mirror page shows it at the top until the person presses \"I've read it\". (d) Every sign-in email's subject is \"123456 is your sign-in code\" (portal and Mirror). Migration 20261119698000. | DECIDED 11/14/2026 |");
fs.writeFileSync(D, L.join("\n"));
ed("docs/human-mirror/DEPLOYMENT.md", "the final text of https://2ndchinc.org/mirror/privacy/. The site never claims compliance. Legal is working on it (11/14/2026).",
  "the final text of https://2ndchinc.org/mirror/privacy/. The site never claims compliance. DONE 11/14/2026: legal's final text is published (D-47).");
ed("docs/human-mirror/NEXT_ACTIONS.md", "then legal's privacy text (K-04), then launch.", "then legal's privacy text (K-04, published 11/14/2026), then launch.");
fs.appendFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", `
### 11/14/2026 — Final privacy page published, its promises built first (Stephen; lease-d6)
- Legal's final text is live at https://2ndchinc.org/mirror/privacy/ (publish checklist removed; backups: "removed automatically within 7 days";
  site icon added). Stephen confirmed the organizational promises on legal's checklist.
- Migration 20261119698000_mirror_privacy_promises.sql (D-47): mirror.individuals.hidden_at and mirror.hide_individual; mirror_my_hide /
  mirror_my_unhide (Settings), mirror_person_hide (People list), mirror_platform_hide (platform page); mirror_people, mirror_org_audit,
  mirror_person_status, mirror_person_add, mirror_my_settings, mirror_my_deletion changed for it; trigger mirror.adults_only (under 18 refused);
  portal_settings.mirror_change_notice, mirror.profiles.notice_seen, mirror_admin_change_notice_set, mirror_notice_seen, mirror_whoami returns
  change_notice and every Mirror page shows it (mirror-client.js). New columns only, no new table.
- auth-send-email: every sign-in email's subject is now "123456 is your sign-in code" (portal and Mirror).
- Checks: p10pp 6/6 rolled back. With the migration in the same transaction, 26 older checks time out in the refusal writer's second
  connection (the uncommitted alter table holds the lock); they are re-run on live after the migration is applied.
`);
const H = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt";
ed(H, "34.   [WAITING FOR LEGAL 11/14/2026, D-46] Privacy: K-04", "34.   [DONE 11/14/2026, D-47, migration 20261119698000] Privacy: K-04");
console.log("ok");
