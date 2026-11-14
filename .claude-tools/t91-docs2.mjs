import fs from "node:fs";
import { execSync } from "node:child_process";
// For each doc: apply my change to BOTH the HEAD version (written to .claude-tools/stage/<path>, the only thing committed) and the working file.
const both = (path, fn) => {
  const head = execSync(`git show HEAD:${path}`, { encoding: "utf8", maxBuffer: 64e6 });
  const work = fs.readFileSync(path, "utf8");
  const h2 = fn(head), w2 = fn(work);
  if (h2 === head || w2 === work) { console.log("MISS", path); process.exit(1); }
  fs.mkdirSync(".claude-tools/stage/" + path.split("/").slice(0, -1).join("/"), { recursive: true });
  fs.writeFileSync(".claude-tools/stage/" + path, h2); fs.writeFileSync(path, w2); console.log("ok", path);
};
const afterRow = (start, row) => (s) => { const i = s.indexOf("
" + start); if (i < 0) return s; const e = s.indexOf("
", i + 1); return s.slice(0, e + 1) + row + "
" + s.slice(e + 1); };
const once = (a, b) => (s) => (s.split(a).length === 2 ? s.replace(a, b) : s);
both("docs/human-mirror/MASTER_ROADMAP.md", once("**T9.1 Templates and preferences** (M) — `mirror.email_html(kind, data)`, notification_prefs, kinds per ARCHITECTURE section 6.",
  "**T9.1 Templates and preferences** (M) — `mirror.email_html(kind, data)`, notification_prefs, kinds per ARCHITECTURE section 6. Status: BUILT + LIVE 11/13/2026 (migration 20261119660000, check t91 5/5, D-42): mirror.email_html (6 kinds, no details, safety mode neutral with the link https://2ndchinc.org/account/), mirror.email_queue (the one way; the person's choices and safety mode via mirror.notification_ok; repeats within 12 hours skipped; every attempt in mirror.notifications), THE HOLD (portal_settings.mirror_email_kinds_enabled starts empty: nothing is sent until the main admin turns a kind on at https://2ndchinc.org/mirror/admin/email/). Choices in Settings were already built (Phase 3 fix 5, D-25)."));
both("docs/human-mirror/DECISIONS.md", afterRow("| D-40 |", "| D-42 | **Mirror emails (T9.1, 11/13/2026).** Chosen by Claude, for Stephen to confirm: (a) every Mirror email goes through mirror.email_queue and its words live only in mirror.email_html; (b) each kind is OFF until the 2nd Chance main admin (portal_admins) turns it on at https://2ndchinc.org/mirror/admin/email/, where platform admins see the exact words; while off, emails are recorded as held and never sent, and are not sent later; (c) emails say only what kind of thing is waiting and link to sign in; (d) for a person in safety mode the always-sent kinds (security, invitation) say only \"2nd Chance Housing\" and link to https://2ndchinc.org/account/ (a redirect to the Mirror sign-in, so \"mirror\" is not in the email); the three choice kinds are not sent at all (D-25); (e) the same item is not emailed twice within 12 hours; (f) mirror.notifications keeps who, kind, when and held/queued/skipped with the reason, never the words. | DEFAULT (confirm) |\n| D-41 |"));
both("docs/human-mirror/DATABASE_DESIGN.md", once("| notifications | recipient_email, kind, outbox_id, created_at, read_at | Links to `public.email_outbox`. |",
  "| notifications | recipient_email, individual_id, kind, ref, status (held, queued, skipped), reason, outbox_id, created_at | Every Mirror email attempt (T9.1, migration 20261119660000); outbox_id links to `public.email_outbox` when queued. No words stored. |"));
both("docs/human-mirror/SITEMAP.md", once("configuration, security and data management as sections of /mirror/admin/platform/",
  "configuration, security and data management as sections of /mirror/admin/platform/; email/ = every Mirror email's words and the on/off hold per kind (T9.1, built 11/13/2026)"));
both("docs/human-mirror/DEVELOPMENT_STATUS.md", (s) => s.trimEnd() + `

### 11/13/2026 — Phase 9 step 23, T9.1: email templates and the hold (Stephen: "you take phase 9 now")
- Migration 20261119660000_mirror_email_templates.sql: table mirror.notifications (service_role only); mirror.email_kinds, mirror.email_html (words for
  the 6 kinds; no health, legal, money or safety detail; safety mode neutral), mirror.email_queue (the one way to queue; notification_ok for the 3
  choice kinds; 12-hour repeat guard; held unless the kind is in portal_settings.mirror_email_kinds_enabled, which starts empty),
  mirror_admin_email_kinds / mirror_admin_email_kind_set (platform admins see; only portal_admins switch; logged). D-42 DEFAULT.
- Pages: new https://2ndchinc.org/mirror/admin/email/ (exact words in sandboxed previews, on/off, 30-day counts), linked from the platform page's
  Email section. site/_redirects: /account/ -> /mirror/sign-in/ (neutral link for safety mode).
- Nothing calls email_queue yet, and every kind is off: no email is sent. Next: T2.6 second half (the invitation), then T9.2 reminders.
- Checks: t91 5/5 rolled back; all 32 Mirror checks pass with the migration.
` + "\n");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("23.   T9.1 Templates and preferences", "23.   [DONE 11/13/2026, migration 20261119660000] T9.1 Templates and preferences"); fs.writeFileSync(h, t); console.log("ticked");
