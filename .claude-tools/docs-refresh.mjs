// One-off: bring the Human Mirror status docs and the bug-check rotation up to date (11/13/2026, lease-bc).
import fs from 'node:fs';
const swap = (file, from, to) => {
  let s = fs.readFileSync(file, 'utf8');
  if (s.split(from).length !== 2) throw new Error('anchor not found once in ' + file + ': ' + from.slice(0, 60));
  fs.writeFileSync(file, s.replace(from, to));
};

const ds = 'docs/human-mirror/DEVELOPMENT_STATUS.md';
swap(ds, 'Built and live at https://2ndchinc.org/mirror/ (noindex, not linked from the main site): Phase 1 foundation (design system, public\npages, sign-in page, Speak / Read aloud, conversation preview), Phase 2 schema `mirror` with consents, roles and audit, Phase 3 Individual\nMirror and Phase 4 Daily Number (in progress; see the session log).',
  'Built and live at https://2ndchinc.org/mirror/ (noindex, not linked from the main site): Phases 1, 3, 4 and 5, Phase 2 except its open\nfixes, and Phase 6 except T6.4 (as of 11/13/2026; see the table and the session log). Latest Mirror migrations live: 20261119360000\n(T1.6) and 20261119269700 (Phase 2 finding E).');
swap(ds, '| 5 Functional and housing assessment | BUILT AND LIVE 11/13/2026 (not complete under Part 14) | T5.1 + T5.2 built, live',
  '| 5 Functional and housing assessment | BUILT AND LIVE 11/13/2026 (not complete under Part 14) | P5-02 is no longer blocked: Settings already has the Phase 6 and T1.6 edits, but does not yet call mirror_my_export_living. T5.1 + T5.2 built, live');
swap(ds, '| 6-10 | LATER | |',
  '| 6 Personal development | IN PROGRESS (3 of 4) | T6.1 needs, T6.2 strengths, T6.3 goals, steps and milestones built and live 11/13 (D-27, D-29, D-30 confirmed). Left: T6.4 progress page. Coordinators see none of it until Phase 8. |\n| 7, 8, N, 9, 10 | NOT STARTED | About 33-45 of the roadmap\'s 70-95 sessions remain (about 47%), counting T6.4. |');

const na = 'docs/human-mirror/NEXT_ACTIONS.md';
swap(na, '1. D-01 and D-03 decided 11/12 (read-only checks; invite only).',
  '1. **Now (11/13/2026): T6.4 progress page** (S): counts per life area (D-09, never a score) and history over time; it finishes Phase 6.\n   Also open: P5-02 (add the Phase 5 records to Settings\' "Download everything"; no longer blocked), Phase 2 fixes P2-06 to P2-13 and P2-15,\n   T2.6 second half (/mirror/register/ and the invitation email), D-31 (T1.6 defaults) for Stephen to confirm.\n   Then Phase 7 (T7.1 first), Phase 8, Phase N, Phase 9, Phase 10.\n\nHistory (done):\n\n1a. D-01 and D-03 decided 11/12 (read-only checks; invite only).');

const bc = 'docs/BUG-CHECK-ROTATION.md';
swap(bc, '**Next up: 7**', '**Next up: 8**');
swap(bc, 'only the 4 intended anon functions (condo_confirm_by_token, notice_deadline, public_units_under_contract, public_units_leased)',
  'only the 5 intended anon functions (condo_confirm_by_token, notice_deadline, public_units_under_contract, public_units_leased, and since the waitlist public_units_rent_ready)');
swap(bc, 'the page answers 200 and `auth-send-email` is ACTIVE.',
  'the page answers 200 and `auth-send-email` is ACTIVE. Since 11/13/2026 (Phase 2 finding E): `mirror.platform_admins` holds the Mirror platform admins (count only; it must never be empty, and every active row is an active member of 2nd Chance Housing in the Mirror); https://2ndchinc.org/mirror/admin/ answers 200.');
let s = fs.readFileSync(bc, 'utf8').replace(/\s*$/, '\n');
s += '- 2026-11-13 (segment 7): refusal channel ok; mirror_link no USAGE for anon/authenticated/service_role; mirror_refusal_writer limit 3, no inherit; 145 sessions (oldest 10/10); 38 auth users (36 on 11/11); 10 idle + 10 max-day settings and step_up_minutes present; 3 step_up_codes (none new, 0 with many attempts); audit log still empty (known gap); 0 storage policies reading a table authenticated cannot select; anon functions = the 4 listed + public_units_rent_ready (waitlist, granted on purpose; list updated); Auth CAPTCHA on (Turnstile, secret set); /sign-in/, /mirror/sign-in/, /mirror/admin/ 200; 4 of 4 security headers; auth-send-email ACTIVE; Mirror switch off; 2 platform admins (finding E), both active 2nd Chance members. OK. Not re-run: advisor, uptime workflow, rolled-back tenant upload, role-less user count (total grew by 2). Next up: 8.\n';
fs.writeFileSync(bc, s);
console.log('ok');
