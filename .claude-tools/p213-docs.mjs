// P2-13 doc updates (one-off; not committed). BUG-CHECK-ROTATION.md: only my line is staged (another session's edits stay unstaged).
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d41 = "| D-41 | **One place for the access rules (P2-13, 11/13/2026).** Chosen by Claude (Stephen: \"go to phase 10\"; same powers as before, nothing for him to choose): every permission decision asks mirror.role_permissions. Two capabilities joined it: 'workspace' (view: work with the organization's people; organization admin and coordinator) and 'confirm' (edit: confirm a need met or a milestone; organization admin and coordinator). 'organization' (edit) = manage members and services; 'audit' (view) = the organization's audit log. Helpers mirror.role_can and mirror.i_can. Role names stay only where they are identities (audit labels, ordering, keep at least one admin, the roles a member may be given, a Navigator as admin of their own business). Migration 20261119596000. | DECIDED 11/13/2026 |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-40 | **Platform admin pages";
if (!dec.includes(anchor) || dec.includes("| D-41 |")) { console.error("D-40 anchor missing or D-41 taken"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec.slice(0, i) + d41 + dec.slice(i)); console.log("ok DECISIONS");
edit("docs/human-mirror/KNOWN_ISSUES.md", [
  ["| P2-13 | Access rules live in two places (permission matrix and admin functions). | Open |",
   "| P2-13 | Access rules live in two places (permission matrix and admin functions). Fixed 11/13/2026: every permission decision asks mirror.role_permissions (new capabilities 'workspace' and 'confirm'; helpers mirror.role_can, mirror.i_can; 12 functions changed, same powers as before; migration 20261119596000, check p213 4/4, D-41). | Fixed 11/13/2026 |"],
]);
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["  not on the list and for another organization). html-validate and module syntax ok. Phase 8 has no open items left but the Guided Tour.",
   "  not on the list and for another organization). html-validate and module syntax ok. Phase 8 has no open items left but the Guided Tour.\n\n" +
   "### 11/13/2026 — Phase 10 step 29: P2-13 one place for the access rules (Stephen: \"go to phase 10\"; Phase 9 is lease-30's)\n" +
   "- Migration 20261119596000_mirror_one_place_for_rules.sql: role_permissions gets 'workspace' (view) and 'confirm' (edit) for organization\n" +
   "  admins and coordinators; mirror.role_can / mirror.i_can; 12 live function bodies changed only in their role checks (coordinates,\n" +
   "  can_manage_members, platform_outside, authenticator_reset_refusal, conv_member, mirror_admin_orgs, mirror_need_status,\n" +
   "  mirror_milestone_confirm, mirror_org_audit, mirror_services, mirror_service_save, mirror_admin_authenticator_reset). D-41.\n" +
   "- Check p213 4/4 (no function decides by naming a role; same powers per role; removing a table row takes a power away, adding one\n" +
   "  gives it). Every Mirror check run with and without the migration (see below). The platform page names the two new capabilities."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["## Phase 10: Production readiness (size M)", "## Phase 10: Production readiness (size M) — IN PROGRESS (P2-13 one place for the rules done 11/13/2026, D-41)"],
]);
const f = "docs/BUG-CHECK-ROTATION.md";
const a = "p208 still 4/4 (rolled back); https://2ndchinc.org/mirror/admin/platform/ returns 200.";
const b = a + " P2-13 (11/13/2026, migration 20261119596000): p213 still 4/4 (rolled back): no Mirror function decides a permission by naming a role; mirror.role_permissions has the 'workspace' and 'confirm' rows for org_admin and coordinator.";
edit(f, [[a, b]]);
const head = execFileSync("git", ["show", "HEAD:" + f], { encoding: "utf8" });
if (!head.includes(a)) { console.error("HEAD lacks anchor"); process.exit(1); }
const tmp = path.join(os.tmpdir(), "bugcheck-staged-p213.md");
fs.writeFileSync(tmp, head.replace(a, b));
const blob = execFileSync("git", ["hash-object", "-w", tmp], { encoding: "utf8" }).trim();
execFileSync("git", ["update-index", "--cacheinfo", "100644," + blob + "," + f]);
fs.unlinkSync(tmp);
console.log("staged my line in " + f);
