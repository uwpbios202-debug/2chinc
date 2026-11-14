// P2-15 doc updates (one-off; not committed). BUG-CHECK-ROTATION.md: only my line is staged (another session's edits stay unstaged).
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d42 = "| D-43 | **Rate limits (P2-15, 11/13/2026).** Chosen by Claude (Stephen: \"go\"), limits generous so normal work never meets them: per sign-in, counted per minute (mirror.rate_counts): changes through the gate 600 per 10 minutes; an organization member's counted looks (every look at a private topic, every direct read of a record; not quiet probes, so everyday list views are not counted) 3,000 an hour; adding people 100 an hour; sending referrals (emails the office) 30 an hour; reports 60 an hour; platform pages 300 an hour. Over a limit the plain message \"Too many in a short time. Please wait a few minutes and try again.\" (errcode 54000); a member's refusal is in the audit log at most once per 10 minutes; the person's own reading is never limited. All limits in one function, mirror.rate_limit(bucket). Sign-in codes stay limited by Supabase Auth and Turnstile. Migration 20261119597000. | DECIDED 11/13/2026 (Stephen can change a number) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-42 | **Mirror emails (T9.1";
if (!dec.includes(anchor) || dec.includes("| D-43 |")) { console.error("D-42 anchor missing or D-43 taken"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec.slice(0, i) + d42 + dec.slice(i)); console.log("ok DECISIONS");
edit("docs/human-mirror/KNOWN_ISSUES.md", [
  ["| P2-15 | No rate limits. | Open |",
   "| P2-15 | No rate limits. Fixed 11/13/2026: per sign-in limits on changes, members' counted looks, adding people, referrals, reports and platform pages, one function mirror.rate_limit, plain message, refusal logged once per 10 minutes (migration 20261119597000, check p215 5/5, D-43). Everyday list views use quiet probes and are not counted. | Fixed 11/13/2026 |"],
]);
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["  (56 report; t71 1 failed part, lrd and t72 setup errors, and t91 waiting for Phase 9 are the same without it). The platform page names the two new capabilities.",
   "  (56 report; t71 1 failed part, lrd and t72 setup errors, and t91 waiting for Phase 9 are the same without it). The platform page names the two new capabilities.\n\n" +
   "### 11/13/2026 — Phase 10 step 30: P2-15 rate limits (Stephen: \"go\")\n" +
   "- Migration 20261119597000_mirror_rate_limits.sql: table mirror.rate_counts (per sign-in, bucket, minute; row security on, service_role\n" +
   "  only), mirror.rate_limit / rate_ok / rate_require / rate_message / rate_refused, index audit_logs_rate. The gate (mirror.allowed, live\n" +
   "  body) counts changes and members' non-probe looks; mirror_person_add, mirror_referral_send, mirror_org_report and the two platform\n" +
   "  functions have their own limits (live bodies, one line added each). No read-only (STABLE) function reaches a counted path (checked). D-43.\n" +
   "- Check p215 5/5 (limits; a look counted, probes not; refusals with the plain message for a member's look, the person's change, adding\n" +
   "  people; the refusal logged once; old counts expire). All Mirror checks run with and without the migration (results below)."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["— IN PROGRESS (P2-13 one place for the rules done 11/13/2026, D-41)", "— IN PROGRESS (P2-13 one place for the rules, D-41, and P2-15 rate limits, D-43, done 11/13/2026)"],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["Phase 10 started here: P2-13 done (D-41), next P2-15 rate limits.", "Phase 10 started here: P2-13 done (D-41), P2-15 rate limits done (D-43); next the security review (step 31, after Phase 9 lands) or the accessibility, phone and performance pass (step 32)."],
]);
const f = "docs/BUG-CHECK-ROTATION.md";
const a = "mirror.role_permissions has the 'workspace' and 'confirm' rows for org_admin and coordinator.";
const b = a + " P2-15 (11/13/2026, migration 20261119597000): mirror.rate_counts has row security and no anon/authenticated grants; no row older than 2 days in large numbers (count only); p215 still 5/5 (rolled back).";
edit(f, [[a, b]]);
const head = execFileSync("git", ["show", "HEAD:" + f], { encoding: "utf8" });
if (!head.includes(a)) { console.error("HEAD lacks anchor"); process.exit(1); }
const tmp = path.join(os.tmpdir(), "bugcheck-staged-p215.md");
fs.writeFileSync(tmp, head.replace(a, b));
const blob = execFileSync("git", ["hash-object", "-w", tmp], { encoding: "utf8" }).trim();
execFileSync("git", ["update-index", "--cacheinfo", "100644," + blob + "," + f]);
fs.unlinkSync(tmp);
console.log("staged my line in " + f);
