// T8.5 doc updates (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d35 = "| D-35 | **Appointments and contact notes (T8.5, 11/13/2026).** Defaults chosen by Claude, for Stephen to confirm: (a) a coordinator adds an appointment for their own organization only with the person's \"see and change\" for its topic (the area of life chosen, else everyday); (b) the person sees all their appointments with every organization on My appointments (/mirror/my-mirror/appointments/) and may add their own, which no organization sees; (c) on an organization's appointment the person may say \"I can't make it\" or \"It happened\"; the organization changes the rest; statuses coming up / happened / cancelled / didn't happen, never \"missed\" or \"no-show\"; every change in the appointment's history; nothing deleted one by one; (d) the dashboard lists the organization's appointments today and the next 7 days, shared topics only; (e) no reminder email until Phase 9 (T9.2, D-25); (f) contact notes (visit, call, message, meeting, other) are written only with \"see and change\" for the note's topic; (g) **no secret notes**: the person sees every note any organization writes about them, with the writer's name (Notes about me, /mirror/my-mirror/notes/); (h) an organization sees only its own notes in shared topics; private looks logged; (i) notes never change; a correction is a new linked note; deleting the whole Mirror removes them. Tables mirror.appointments, appointment_events, interactions (migration 20261119550000). | DEFAULT (confirm) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-34 | **Services and enrollments";
if (!dec.includes(anchor)) { console.error("no D-34 anchor"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
dec = dec.slice(0, i) + d35 + dec.slice(i);
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec); console.log("ok DECISIONS");
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["| 8 Organization workspace | IN PROGRESS (4 of 8) |", "| 8 Organization workspace | IN PROGRESS (5 of 8) |"],
  ["(migration 20261119540000, t84 6/6, D-34 DEFAULT). Next: T8.5 appointments and interactions.",
   "(migration 20261119540000, t84 6/6, D-34 DEFAULT). T8.5 appointments and contact notes built and live 11/13 (migration 20261119550000, t85 7/7, D-35 DEFAULT). Next: T8.6 benefits applications."],
  ["- Checks: t84 6/6 rolled back on live. html-validate and module syntax ok on the 6 touched pages and workspace-person.js.",
   "- Checks: t84 6/6 rolled back on live. html-validate and module syntax ok on the 6 touched pages and workspace-person.js.\n\n" +
   "### 11/13/2026 — Phase 8 T8.5: appointments and contact notes (Stephen: \"go\")\n" +
   "- Migration 20261119550000_mirror_appointments_notes.sql: tables mirror.appointments, appointment_events, interactions (row security on,\n" +
   "  service_role only, no TRUNCATE; interactions append-only by trigger, removed only with the whole Mirror). Functions mirror_appointments,\n" +
   "  mirror_appointment_save, mirror_workspace_appointments (dashboard, today + 7 days), mirror_interactions, mirror_interaction_add (corrections\n" +
   "  link to the note), mirror_my_export_appointments. D-35 DEFAULT for Stephen to confirm (no secret notes; the person's own appointments are theirs).\n" +
   "- Pages: Appointments and Contact notes sections on /mirror/workspace/person/ (workspace-person.js ?v=20261113c); the dashboard lists\n" +
   "  appointments today and this week; new https://2ndchinc.org/mirror/my-mirror/appointments/ (add my own; \"I can't make it\" / \"It happened\")\n" +
   "  and https://2ndchinc.org/mirror/my-mirror/notes/ (Notes about me), linked from My Mirror; Settings' download and printable copy include both.\n" +
   "- Checks: t85 7/7 rolled back on live (incl. whole-Mirror deletion removes appointments and notes). html-validate and module syntax ok.\n" +
   "- Not yet: reminder emails (Phase 9, T9.2)."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["**T8.5 Appointments and interactions** (M).", "**T8.5 Appointments and interactions** (M) — Status: DONE 11/13/2026 (migration 20261119550000, t85 7/7, D-35)."],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["T8.3 and T8.4 done 11/13 (D-34 DEFAULT to confirm); next T8.5 appointments and interactions (M).",
   "T8.3, T8.4 and T8.5 done 11/13 (D-34, D-35 DEFAULT to confirm); next T8.6 benefits applications (S)."],
]);
edit("docs/human-mirror/DATABASE_DESIGN.md", [
  ["| appointments | individual_id, organization_id, starts_at, place, with_whom, purpose_category, reminder_at, status | |\n| interactions | individual_id, organization_id, member_id, kind (visit, call, message), at, summary, sensitive_category | Case notes. |",
   "| appointments | individual_id, organization_id (null = the person's own), dimension_key, category, title, starts_at, ends_at, place, with_whom, detail, status (scheduled, done, cancelled, not_happened), created_by(_role) | History in appointment_events. Reminders come with Phase 9 (T9.2). T8.5, migration 20261119550000, D-35. |\n| interactions | individual_id, organization_id, category, kind (visit, call, message, meeting, other), at, summary, corrects, by_email, by_name, by_role | Contact notes. Append-only (a correction is a new note); the person sees every note (D-35). |"],
]);
edit("docs/human-mirror/SITEMAP.md", [
  ["| appointments/ | My appointments | 8 |", "| appointments/ | My appointments: with organizations and my own (mine stay mine); \"I can't make it\" / \"It happened\"; history (T8.5, D-35; built 11/13/2026) | 8 |\n| notes/ | Notes about me: every contact note an organization writes, with the writer (T8.5, D-35; built 11/13/2026) | 8 |"],
  ["| appointments/ | Scheduling and follow-up | 8 |", "| appointments/ | Scheduling and follow-up: built on person/ (Appointments, Contact notes) and the dashboard (today and this week), T8.5 11/13/2026; no separate page | 8 |"],
]);
edit("docs/BUG-CHECK-ROTATION.md", [
  ["https://2ndchinc.org/mirror/workspace/services/ and https://2ndchinc.org/mirror/my-mirror/services/ return 200.",
   "https://2ndchinc.org/mirror/workspace/services/ and https://2ndchinc.org/mirror/my-mirror/services/ return 200. T8.5 (11/13/2026, migration 20261119550000): appointments, appointment_events, interactions have row security and no anon/authenticated/PUBLIC grants; trigger interactions_append_only exists; 0 interactions whose organization does not work with that person, 0 appointments with ends_at before starts_at (counts only; never read or quote notes); t85 still 7/7 (rolled back); https://2ndchinc.org/mirror/my-mirror/appointments/ and https://2ndchinc.org/mirror/my-mirror/notes/ return 200."],
]);
