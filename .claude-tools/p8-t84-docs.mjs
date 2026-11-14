import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 90)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d34 = "| D-34 | **Services and enrollments (T8.4, 11/13/2026).** Defaults chosen by Claude, for Stephen to confirm: (a) an organization's own services (what it provides itself; other organizations' programs stay in the directory) are added, changed and retired by its organization admins; coordinators read the list; a service with enrollments is retired, never deleted; (b) a service may name one area of life and takes that area's privacy topic (else everyday); the area can't change once someone is enrolled; (c) a coordinator enrolls, puts on hold, marks finished or stopped only with the person's \"see and change\" for that topic; (d) the person sees all their enrollments with every organization on My services (/mirror/my-mirror/services/), with the history, and may say they stopped getting one; only the organization marks on hold or finished; nobody removes one (whole-Mirror deletion does); (e) an organization sees only its own enrollments in shared topics; counts beside a service include only those; private looks are logged; (f) every change is in the enrollment's history; no email; (g) statuses: getting it, on hold, finished, stopped. Tables mirror.services, service_enrollments, service_enrollment_events (migration 20261119540000). | DEFAULT (confirm) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-31 | **Conversation guide, saved";
if (!dec.includes(anchor)) { console.error("no D-31 anchor"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
dec = dec.slice(0, i) + d34 + dec.slice(i);
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec); console.log("ok DECISIONS");
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["| 8 Organization workspace | IN PROGRESS (3 of 8) |", "| 8 Organization workspace | IN PROGRESS (4 of 8) |"],
  ["(migration 20261119530000, t83 6/6). Next: T8.4 services and enrollments.",
   "(migration 20261119530000, t83 6/6). T8.4 services and enrollments built and live 11/13 (migration 20261119540000, t84 6/6, D-34 DEFAULT). Next: T8.5 appointments and interactions."],
  ["- Not yet: a set marked \"finished\" together (assessments.completed_at is never set; one assessment row per person and set).",
   "- Not yet: a set marked \"finished\" together (assessments.completed_at is never set; one assessment row per person and set).\n\n" +
   "### 11/13/2026 — Phase 8 T8.4: services and enrollments (Stephen: \"go\")\n" +
   "- Migration 20261119540000_mirror_services.sql: tables mirror.services, service_enrollments, service_enrollment_events (row security on,\n" +
   "  service_role only, no TRUNCATE); functions mirror_services, mirror_service_save (organization admins), mirror_enrollments (the person: all\n" +
   "  theirs; a coordinator: their organization's in shared topics, plus services they may enroll in), mirror_enrollment_save (coordinator with\n" +
   "  \"see and change\" for the topic; the person may only say they stopped), mirror_my_export_services. D-34 DEFAULT for Stephen to confirm.\n" +
   "- Pages: new https://2ndchinc.org/mirror/workspace/services/ (\"Our services\", from the dashboard), new https://2ndchinc.org/mirror/my-mirror/services/\n" +
   "  (\"My services\", from My Mirror); a Services section on /mirror/workspace/person/ (workspace-person.js ?v=20261113b: enroll, change where it\n" +
   "  stands, history); Settings' download and printable copy include services (the download sentence now also names resources, referrals, documents).\n" +
   "- Checks: t84 6/6 rolled back on live. html-validate and module syntax ok on the 6 touched pages and workspace-person.js."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["**T8.4 Services and enrollments** (S).", "**T8.4 Services and enrollments** (S) — Status: DONE 11/13/2026 (migration 20261119540000, t84 6/6, D-34)."],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["T8.2 + P2-06 and T8.3 done 11/13; next T8.4 services and enrollments (S).", "T8.2 + P2-06, T8.3 and T8.4 done 11/13 (D-34 DEFAULT to confirm); next T8.5 appointments and interactions (M)."],
]);
edit("docs/human-mirror/DATABASE_DESIGN.md", [
  ["| services | organization_id, name, description, active | What the organization itself provides. |\n| service_enrollments | individual_id, service_id, status, started_on, ended_on | |",
   "| services | organization_id, name, description, dimension_key, category, active, created_by | What the organization itself provides; organization admins keep it (T8.4, migration 20261119540000, D-34). |\n| service_enrollments | individual_id, service_id, organization_id, category, status (active, paused, completed, ended), started_on, ended_on, note, enrolled_by(_role) | One open per person and service; history in service_enrollment_events (from/to status, note, by role). |"],
]);
edit("docs/BUG-CHECK-ROTATION.md", [
  ["t83 still 6/6 (rolled back); https://2ndchinc.org/mirror/workspace/assessments/ returns 200.",
   "t83 still 6/6 (rolled back); https://2ndchinc.org/mirror/workspace/assessments/ returns 200. T8.4 (11/13/2026, migration 20261119540000): services, service_enrollments, service_enrollment_events have row security and no anon/authenticated/PUBLIC grants; 0 enrollments whose category differs from their service's, 0 whose organization differs from their service's, 0 open (active/paused) with an ended_on (counts only); t84 still 6/6 (rolled back); https://2ndchinc.org/mirror/workspace/services/ and https://2ndchinc.org/mirror/my-mirror/services/ return 200."],
]);
