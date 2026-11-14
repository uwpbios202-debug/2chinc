// Doc edits for Phase 8 T8.1 + P2-07 (11/13/2026). Each replace must match exactly once.
import fs from "node:fs";
const edits = [
  ["docs/human-mirror/DEVELOPMENT_STATUS.md", /(\| 6 Personal development \|[^\n]*\n)/,
   "$1| 8 Organization workspace | IN PROGRESS (1 of 8) | T8.1 dashboard and people list + P2-07 (organization's own audit log) built and live 11/13 (migration 20261119500000, t81 6/6). Next: T8.2 one-person overview (with P2-06 safety banner). Guided Tour (deferred, D-28). |\n"],
  ["docs/human-mirror/KNOWN_ISSUES.md", "| P2-07 | No organization or platform view of the audit log. | Open |",
   "| P2-07 | No organization or platform view of the audit log. Organization view fixed 11/13/2026 with T8.1 (mirror_org_audit, https://2ndchinc.org/mirror/workspace/audit/, organization admins only, names never emails). The platform admin's view of every organization moves to P2-08. | Fixed 11/13/2026 (organization view) |"],
  ["docs/human-mirror/MASTER_ROADMAP.md", "**T8.1 Workspace dashboard and people list** (M).",
   "**T8.1 Workspace dashboard and people list** (M). Status: BUILT + LIVE 11/13/2026 (migration 20261119500000: mirror_workspace_dashboard, mirror_people_counts, mirror_org_audit (P2-07); pages /mirror/workspace/, people/ (search, filter, counts), audit/; check t81 6/6). Appointments on the dashboard wait for T8.5."],
  ["docs/human-mirror/NEXT_ACTIONS.md", "   Then Phase 8, Phase N, Phase 9, Phase 10.",
   "   Phase 8 (this session, Stephen 11/13 \"Now you work ONLY on phase 8\"): T8.1 + P2-07 done 11/13; next T8.2 one-person overview (+ P2-06).\n   Then Phase N, Phase 9, Phase 10."],
  ["docs/human-mirror/SITEMAP.md", "| /mirror/workspace/ | Organization dashboard: urgent safety items, due actions, appointments today | 8 |",
   "| /mirror/workspace/ | Organization dashboard: urgent needs, hope-by dates this week or passed, help asked for (built 11/13/2026, T8.1); appointments today (T8.5) | 8 |\n| audit/ | Who looked and changed what: the organization's own audit log, organization admins only (P2-07, built 11/13/2026) | 8 |"],
  ["docs/BUG-CHECK-ROTATION.md", "0 goals with `from_key` whose category differs from their area's topic (count only).",
   "0 goals with `from_key` whose category differs from their area's topic (count only). Mirror Phase 8 T8.1 (11/13/2026, migration 20261119500000): mirror_workspace_dashboard, mirror_people_counts, mirror_org_audit are security definer with a fixed search_path and not executable by anon; mirror.org_sees and mirror.log_private_looks not executable by authenticated; t81 still 6/6 (rolled back); https://2ndchinc.org/mirror/workspace/, people/, audit/ return 200."],
];
for (const [f, a, b] of edits) {
  const t = fs.readFileSync(f, "utf8");
  const k = typeof a === "string" ? t.split(a).length - 1 : (t.match(new RegExp(a.source, "g")) || []).length;
  if (k !== 1) { console.log("SKIP (" + k + " matches): " + f); continue; }
  fs.writeFileSync(f, typeof a === "string" ? t.replace(a, () => b) : t.replace(a, b));
  console.log("ok " + f);
}
