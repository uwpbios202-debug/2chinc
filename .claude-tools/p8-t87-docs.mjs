// T8.7 doc updates (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const d38 = "| D-38 | **Donated goods (T8.7, 11/13/2026).** Defaults chosen by Claude, for Stephen to confirm: (a) each organization keeps its own inventory (clothing, shoes, coats, bedding, furniture, kitchen, hygiene, baby, school, household, other) with size, who it fits, condition (new, like new, good, fair), season and quantity on hand; coordinators and organization admins manage it (authenticator), volunteers and other organizations don't see it; (b) items hold no one's personal information; quantities never go below 0; (c) giving to a person in the Mirror needs their everyday \"see and change\" and shows on their Mirror (My services, \"Things I received\"); giving to someone not in the Mirror keeps no name, only the count; (d) a gift recorded by mistake is marked returned and the count goes back; nothing is deleted; (e) counts only (on hand, given in 30 days). Tables mirror.inventory_items, inventory_given (migration 20261119570000). | DEFAULT (confirm) |\n";
let dec = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const anchor = "| D-37 | **Benefits applications for organizations";
if (!dec.includes(anchor)) { console.error("no D-37 anchor"); process.exit(1); }
const i = dec.indexOf("\n", dec.indexOf(anchor)) + 1;
fs.writeFileSync("docs/human-mirror/DECISIONS.md", dec.slice(0, i) + d38 + dec.slice(i)); console.log("ok DECISIONS");
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["| 8 Organization workspace | IN PROGRESS (6 of 8) |", "| 8 Organization workspace | IN PROGRESS (7 of 8) |"],
  ["t86 6/6, D-37 decided). Next: T8.7 inventory of donated goods.",
   "t86 6/6, D-37 decided). T8.7 donated goods built and live 11/13 (migration 20261119570000, t87 5/5, D-38 DEFAULT). Next: T8.8 outcomes and reports."],
  ["- Checks: t86 6/6 rolled back on live (incl. the Daily Number link kept after a coordinator's change). html-validate and module syntax ok.",
   "- Checks: t86 6/6 rolled back on live (incl. the Daily Number link kept after a coordinator's change). html-validate and module syntax ok.\n\n" +
   "### 11/13/2026 — Phase 8 T8.7: inventory of donated goods (Stephen: \"let us move on\")\n" +
   "- Migration 20261119570000_mirror_inventory.sql: tables mirror.inventory_items, inventory_given (row security on, service_role only, no\n" +
   "  TRUNCATE). Functions mirror_inventory, mirror_inventory_save, mirror_inventory_give (locks the row; never below 0; a Mirror person needs\n" +
   "  everyday \"see and change\"; outside the Mirror no name), mirror_inventory_return (recorded by mistake), mirror_received, mirror_my_export_received.\n" +
   "- Pages: new https://2ndchinc.org/mirror/workspace/inventory/ (\"Donated goods\", from the dashboard: find, kind, season, fits, on hand / all /\n" +
   "  retired; add, change, give); \"Things given\" section on /mirror/workspace/person/ (workspace-person.js ?v=20261113e); \"Things I received\" on\n" +
   "  https://2ndchinc.org/mirror/my-mirror/services/; Settings' download and printable copy include it. D-38 DEFAULT for Stephen.\n" +
   "- Checks: t87 5/5 rolled back on live. html-validate and module syntax ok on the 5 touched pages and workspace-person.js."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["**T8.7 Inventory of donated goods** (M, clothing sizes/condition/season).", "**T8.7 Inventory of donated goods** (M, clothing sizes/condition/season) — Status: DONE 11/13/2026 (migration 20261119570000, t87 5/5, D-38)."],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["next T8.7 inventory of donated goods (M).", "T8.7 donated goods done 11/13 (D-38 DEFAULT); next T8.8 outcomes and reports (M)."],
]);
edit("docs/human-mirror/DATABASE_DESIGN.md", [
  ["| inventory_items | organization_id, category, item, size, condition, season, quantity, status | Donated goods (Clothes paper section 12). |",
   "| inventory_items | organization_id, category, item, size, fits, condition, season, quantity, location, note, active | Donated goods (Clothes paper section 12). T8.7, migration 20261119570000, D-38. |\n| inventory_given | item_id, organization_id, individual_id (null = not in the Mirror, no name), quantity, given_on, note, given_by(_role), returned_at, returned_note | A mistake is marked returned; the person sees what they received. |"],
]);
edit("docs/human-mirror/SITEMAP.md", [
  ["| inventory/ | Donated goods: clothing, furniture, supplies (sizes, condition, available) | 8 |",
   "| inventory/ | Donated goods: clothing, furniture, supplies (sizes, fits, condition, season, on hand; give to a person or someone not in the Mirror) (T8.7, D-38; built 11/13/2026) | 8 |"],
]);
edit("docs/BUG-CHECK-ROTATION.md", [
  ["t86 still 6/6 (rolled back).",
   "t86 still 6/6 (rolled back). T8.7 (11/13/2026, migration 20261119570000): inventory_items and inventory_given have row security and no anon/authenticated/PUBLIC grants; 0 items with quantity below 0, 0 gifts whose organization differs from their item's (counts only); t87 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/inventory/ returns 200."],
]);
