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
both("docs/human-mirror/MASTER_ROADMAP.md", once("**T9.2 Reminders** (S) — appointment and action reminders through the existing cron pattern. Every first real send of a kind asks Stephen (CLAUDE.md).",
  "**T9.2 Reminders** (S) — appointment and action reminders through the existing cron pattern. Every first real send of a kind asks Stephen (CLAUDE.md). Status: BUILT + LIVE 11/13/2026 (migration 20261119680000, check t92 4/4): mirror.send_reminders, the day before each scheduled appointment and each open plan step due (Milwaukee date), to the person's own sign-in email, date and time only (never the title); job mirror-reminders daily 13:30 UTC (7:30 a.m. Milwaukee in winter); through mirror.email_queue, so the person's choices, safety mode and the hold apply (both kinds off until Stephen turns them on)."));
both("docs/human-mirror/DEVELOPMENT_STATUS.md", (s) => s.trimEnd() + `

### 11/13/2026 — Phase 9 step 25, T9.2: reminders (Stephen: "go")
- Migration 20261119680000_mirror_reminders.sql: mirror.send_reminders (the day before: scheduled appointments starting tomorrow, open plan steps due
  tomorrow; people with their own sign-in email; date and time only; the reference includes the date, so a moved item gets a new reminder and none is
  sent twice) and job mirror-reminders (daily 13:30 UTC; calls outbox-flush with x-cycle-secret only when something was queued). No new table.
- Both kinds (appointment reminders, reminders about the plan) are still off: reminders are recorded as held and not sent until Stephen turns them on.
- Check fixes (stale expectations, not system faults): t72 item 1 now expects a health match (TN.3 added a health center) and the truncate test accepts
  the referrals foreign key (T7.3); t72 6/6 on live.
- Checks: t92 4/4 rolled back; all Mirror checks pass with the migration (the landlord-database check errors the same way without it).
` + "\n");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("25.   T9.2 Reminders (S)", "25.   [DONE 11/13/2026, migration 20261119680000] T9.2 Reminders (S)"); fs.writeFileSync(h, t); console.log("ticked");
