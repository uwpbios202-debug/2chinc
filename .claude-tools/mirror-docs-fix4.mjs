import fs from 'node:fs';
const rep = (p, a, b) => { const s = fs.readFileSync(p, 'utf8'); if (!s.includes(a)) throw new Error('not found in ' + p + ': ' + a.slice(0, 70)); fs.writeFileSync(p, s.replace(a, b)); };
const S = 'docs/human-mirror/DEVELOPMENT_STATUS.md', K = 'docs/human-mirror/KNOWN_ISSUES.md';
rep(S, 'fixes 1, 2, 3 and 14 of 15 done; fixes 4-13 and 15 open (list in KNOWN_ISSUES.md, P2-04 to P2-15)',
       'fixes 1-4 and 14 of 15 done; fixes 5-13 and 15 open (list in KNOWN_ISSUES.md, P2-05 to P2-15)');
rep(S, '### 11/13/2026 — Phase 2 fix 3 of 15 DONE (commit ca6c8f4, migration 20261119267000)',
`### 11/13/2026 — Phase 2 fix 4 of 15 DONE (commit c91d7fc, migration 20261119268000)
- Read on live: mirror.can_manage_members() let a platform admin save members of ANY organization, their own email included, which opens
  that organization's people to them; the only trace was an audit row the organization cannot see.
- Now a platform admin acting where they are not the organization's own admin (mirror.platform_outside) cannot add, reactivate or promote
  themselves, or change a member's email to their own; every member they add or change there is marked (platform_changed_at / _by) and
  /mirror/admin/ shows "Added or changed by <name> (2nd Chance), <date>". Setting up a new organization's members still works.
- Check p2-fix04 (rolled back) 5/5; t25 still 6/6. Live: 0 members marked (only 2nd Chance exists). Site published; applied ALONE
  (another session's uncommitted 20261119287000 left out; it does not touch these tables).
- Chosen default, not asked: 2nd Chance may still add OTHER people to an organization that has its own admin (visible now). A stricter
  rule (only the first admin) is a one-line change if Stephen wants it.

### 11/13/2026 — Phase 2 fix 3 of 15 DONE (commit ca6c8f4, migration 20261119267000)`);
rep(K, 'commit ca6c8f4) and fix 14', 'commit ca6c8f4), fix 4 (2nd Chance admins cannot join another organization unseen, commit c91d7fc) and fix 14');
rep(K, '| P2-04 | 2nd Chance admins can join any organization without anyone seeing it. | Open |\n', '');
console.log('ok');
