import fs from 'node:fs';
const rep = (p, a, b) => { const s = fs.readFileSync(p, 'utf8'); if (!s.includes(a)) throw new Error('not found in ' + p + ': ' + a.slice(0, 70)); fs.writeFileSync(p, s.replace(a, b)); };
const S = 'docs/human-mirror/DEVELOPMENT_STATUS.md', K = 'docs/human-mirror/KNOWN_ISSUES.md';
rep(S, 'fixes 1-4 and 14 of 15 done; fixes 5-13 and 15 open (list in KNOWN_ISSUES.md, P2-05 to P2-15)',
       'fixes 1-5 and 14 of 15 done; fixes 6-13 and 15 open (list in KNOWN_ISSUES.md, P2-06 to P2-15)');
rep(S, '### 11/13/2026 — Phase 2 fix 4 of 15 DONE (commit c91d7fc, migration 20261119268000)',
`### 11/13/2026 — Phase 2 fix 5 of 15 DONE (commit b0c3ed9, migration 20261119269000)
- The Mirror's gates checked only that an email was present, so a remembered device past its idle/maximum days (or signed out everywhere)
  kept working in the Mirror. Now mirror.me(), mirror.signed_in_member_ok() (so my_role / is_platform_admin), mirror.allowed() and
  mirror_who_looked() require public.session_fresh(); mirror_whoami answers signed_in=false, expired=true, so pages ask for a new code.
  Generated from the LIVE bodies with only the session lines added (re-compared with live just before applying: identical). D-22 kept.
- Check p2-fix05 (rolled back, real fictional auth sessions) 5/5. All 16 earlier Mirror checks pass with it.
- FOR EVERY CHECK FROM NOW ON: fictional sign-ins with 'session_id', gen_random_uuid() are now (correctly) expired. Run older checks with
  .claude-tools/mirror-rollback-check-sessions.sh, which swaps in a real fictional session inside the rolled-back transaction.
  (A token with no session_id is treated as View as by autopay_view_as_session, so dropping the id is not an option.)
- Session lengths: Mirror people and non-staff coordinators fall under session_role 'investor' (45 idle / 180 max days); 2nd Chance
  staff under 'staff' (14 / 30). Not changed (D-22); shorter Mirror limits would be Stephen's call.
- MISTAKE: the push also applied another session's uncommitted Phase 5 migration 20261119300000_mirror_functional_housing.sql, which
  appeared between the dry run and the push. Checked after: its 6 tables are empty, row security on, no anon/authenticated grants; no
  Mirror function is anon-callable; its seed 20261119301000 was NOT applied. All sessions were messaged not to push it again.

### 11/13/2026 — Phase 2 fix 4 of 15 DONE (commit c91d7fc, migration 20261119268000)`);
rep(K, 'commit c91d7fc) and fix 14', 'commit c91d7fc), fix 5 (the Mirror honours session_fresh, commit b0c3ed9) and fix 14');
rep(K, '| P2-05 | The Mirror ignores `session_fresh`. | Open |\n', '');
rep(K, "| Check `ls supabase/migrations | tail` and untracked files before every push. |",
  "| Check `ls supabase/migrations | tail` and untracked files before every push. 11/13: it happened twice more (282000 applied by the Phase 4 session; 300000 by the Phase 2 session, which appeared between its dry run and push). Rule: push with `.claude-tools/push-one-migration.sh \"<every other untracked migration>\"`, never a plain `db push --include-all`, and re-list untracked files immediately before. |");
console.log('ok');
