import fs from 'node:fs';
const edit = (f, a, b) => { const s = fs.readFileSync(f, 'utf8'); if (!s.includes(a)) throw new Error('missing in ' + f + ': ' + a.slice(0, 60)); fs.writeFileSync(f, s.replace(a, b)); };
edit('docs/human-mirror/MASTER_ROADMAP.md',
  '**T7.1 Link CHPMS to the Mirror** (S) — resource_categories (program -> dimension, expense category).',
  '**T7.1 Link CHPMS to the Mirror** (S) — resource_categories (program -> dimension, expense category). Status: BUILT + LIVE 11/13/2026 (migration 20261119400000, check tools/mirror-checks/t71-resource-categories-check.sql 6/6): `mirror.resource_assist_map` maps all 20 CHPMS help types to an area (+ cost category); `rule` links follow the CHPMS import by a statement trigger on chpms_program_assist; `office` links (for TN.3) survive every refresh; reader `mirror.program_areas(program)` (service_role only). No browser screen yet (T7.2).');
edit('docs/human-mirror/DATABASE_DESIGN.md',
  '| resource_categories | chpms_program_id, dimension_id, expense_category_id | Links a program to life dimensions and to the Daily Number costs it can lower. |',
  '| resource_categories | chpms_program_id, dimension_key, expense_category_key, source (rule, office), note, added_by | Links a program to life dimensions and to the Daily Number costs it can lower. `rule` rows come from the CHPMS help types through `resource_assist_map` (assist_category, dimension_key, expense_category_key) and are rebuilt on every import; `office` rows are kept (T7.1, 11/13/2026). |');
const bc = 'docs/BUG-CHECK-ROTATION.md';
edit(bc, '**Next up: 9**', '**Next up: 10**');
edit(bc, 'https://2ndchinc.org/mirror/my-mirror/my-needs/, my-strengths/, plan/, actions/, milestones/ return 200.',
  'https://2ndchinc.org/mirror/my-mirror/my-needs/, my-strengths/, plan/, actions/, milestones/ return 200. Mirror Phase 7 T7.1 (11/13/2026, migration 20261119400000): resource_categories and resource_assist_map have row security and no anon/authenticated/PUBLIC grants; every CHPMS program with a provided help type has at least one resource_categories row (the import trigger `chpms_program_assist_mirror_links` exists); t71 still 6/6 (rolled back).');
let s = fs.readFileSync(bc, 'utf8');
s = s.replace(/\s*$/, '\n') + "- 2026-11-13 (segment 9, late night): /waitlist/, /staff/waitlist/, /leasing/apply/, /staff/efile/, /navigator/, /staff/navigators/, /navigator/unit/, /staff/resources/ all 200; 2 waitlist rows, 0 unsent `waitlist_unit`; 0 apply codes and 0 contact messages in 4 days; 0 nav referrals stuck in submitted/matched over 3 days; 0 CHPMS referrals left `new` over 3 days. OK. Not run: eFile STOP lines / case-number age (the case-number column is not on `notices`; recipe to fix), rent-ready order, navigator agreement flags, nav-receipts storage. Next up: 10. Added to segment 12: Mirror T7.1 checks.\n";
fs.writeFileSync(bc, s);
