// P2-08 doc updates (one-off; not committed). BUG-CHECK-ROTATION.md has another session's uncommitted edits: only my line is staged
// there, by building the staged copy from HEAD (the working copy gets the same line too).
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d40 = "| D-40 | **Platform admin pages (P2-08, 11/13/2026).** Defaults chosen by Claude: (a) one page, /mirror/admin/platform/, for 2nd Chance platform admins only (on the list, member of 2nd Chance, authenticator), covering the site map's users, roles, teams, consent, audit, email, configuration, security and data management; (b) counts and rules only, never a person's name, answers or email; (c) the platform audit log names members, never a person: a short code (6 characters of a one-way hash of the person's id) that is the same on every row for the same person; each read of the page and the log is itself logged; (d) read only: settings, role rules and the sign-in switch change only by Stephen's decision; (e) no teams inside an organization: an organization is one team, its members list is the team list (Navigator businesses are their own organizations, D-20); (f) deletion requests are listed by code and date; the deletion run stays Phase 2 fix 9. Migration 20261119595000. | DEFAULT (Stephen said 11/13 to close loops with Claude's defaults) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-39 | **Outcomes and reports";
if (!dec.includes(anchor) || dec.includes("| D-40 |")) { console.error("D-39 anchor missing or D-40 taken"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec.slice(0, i) + d40 + dec.slice(i)); console.log("ok DECISIONS");
edit("docs/human-mirror/KNOWN_ISSUES.md", [
  ["The platform admin's view of every organization moves to P2-08. | Fixed 11/13/2026 (organization view) |",
   "The platform admin's view of every organization moves to P2-08. Platform view fixed 11/13/2026 with P2-08 (mirror_platform_audit on https://2ndchinc.org/mirror/admin/platform/, a person shown only by a code). | Fixed 11/13/2026 |"],
  ["| P2-08 | Admin pages missing: teams, roles, consent, email, data. | Open |",
   "| P2-08 | Admin pages missing: teams, roles, consent, email, data. Fixed 11/13/2026: https://2ndchinc.org/mirror/admin/platform/ (users, organizations, roles, teams note, sharing counts, every organization's audit log, email choices and outbox, Mirror settings, security rules, deletion requests by code and date); platform admins only, counts and rules only, read only, each read logged (migration 20261119595000, check p208 4/4, D-40). | Fixed 11/13/2026 |"],
]);
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["- Phase 8 is built (T8.1-T8.8). Open: P2-08 admin pages (teams, roles, consent, email, data, platform audit view); Guided Tour (deferred, D-28).",
   "- Phase 8 is built (T8.1-T8.8). Open: P2-08 admin pages (teams, roles, consent, email, data, platform audit view); Guided Tour (deferred, D-28).\n\n" +
   "### 11/13/2026 — P2-08: the platform admin pages (Stephen: \"then go\"); D-38 and D-39 decided\n" +
   "- Why it was still open: the site map lists ten /mirror/admin/ sections; Phase 2 (T2.5) built organizations, members and platform admins;\n" +
   "  the deep-dive put the rest last because they report on things built later (sharing records, the organization audit view in T8.1, email).\n" +
   "- Migration 20261119595000_mirror_platform_admin_pages.sql: public.mirror_platform_overview (users, members by role and authenticator,\n" +
   "  organizations, role rules, sharing counts, email choices and Mirror outbox, Mirror settings, deletion requests by code and date) and\n" +
   "  public.mirror_platform_audit (every organization's log, members by name, a person only by a code; P2-07 platform half). Platform admins\n" +
   "  only; counts and rules only; each read logged. No new tables. D-40.\n" +
   "- Page: new https://2ndchinc.org/mirror/admin/platform/ (\"Platform overview\", linked from https://2ndchinc.org/mirror/admin/ for platform admins).\n" +
   "- Checks: p208 4/4 rolled back on live (no name, no email in either result; refused without the authenticator, for a 2nd Chance admin\n" +
   "  not on the list and for another organization). html-validate and module syntax ok. Phase 8 has no open items left but the Guided Tour."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["## Phase 8: Organization workspace (size L) — BUILT AND LIVE 11/13/2026 (T8.1-T8.8; open: P2-08; Guided Tour (deferred, D-28))",
   "## Phase 8: Organization workspace (size L) — BUILT AND LIVE 11/13/2026 (T8.1-T8.8 and P2-08 platform admin pages; open: Guided Tour (deferred, D-28))"],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["Phase 8 built; next P2-08 admin pages (M).", "Phase 8 built; P2-08 platform admin pages done 11/13 (D-40). Phase 8 complete except the Guided Tour (D-28)."],
]);
edit("docs/human-mirror/SITEMAP.md", [
  ["users/ · roles/ · organizations/ · teams/ · consent/ · audit/ · email/ · configuration/ · security/ · data-management/ — all **A**,",
   "Built 11/13/2026 (P2-08, D-40): organizations and members at /mirror/admin/; users, roles, teams (none: an organization is the team), consent, audit, email,\nconfiguration, security and data management as sections of /mirror/admin/platform/ (read only, counts and rules only). Planned list: users/ · roles/ · organizations/ · teams/ · consent/ · audit/ · email/ · configuration/ · security/ · data-management/ — all **A**,"],
]);
// BUG-CHECK-ROTATION.md: my line, in the working copy and staged from HEAD
const f = "docs/BUG-CHECK-ROTATION.md";
const a = "t88 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/reports/ returns 200.";
const b = a + " P2-08 (11/13/2026, migration 20261119595000): mirror_platform_overview and mirror_platform_audit are security definer with a fixed search_path and not executable by anon; p208 still 4/4 (rolled back); https://2ndchinc.org/mirror/admin/platform/ returns 200.";
edit(f, [[a, b]]);
let head = execFileSync("git", ["show", "HEAD:" + f], { encoding: "utf8" });
if (!head.includes(a)) { console.error("HEAD lacks anchor"); process.exit(1); }
const tmp = path.join(os.tmpdir(), "bugcheck-staged-p208.md");
fs.writeFileSync(tmp, head.replace(a, b));
const blob = execFileSync("git", ["hash-object", "-w", tmp], { encoding: "utf8" }).trim();
execFileSync("git", ["update-index", "--cacheinfo", "100644," + blob + "," + f]);
fs.unlinkSync(tmp);
console.log("staged my line in " + f);
