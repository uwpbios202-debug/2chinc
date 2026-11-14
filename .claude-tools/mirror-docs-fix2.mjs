import fs from 'node:fs';
const rep = (p, a, b) => { const s = fs.readFileSync(p, 'utf8'); if (!s.includes(a)) throw new Error('not found in ' + p + ': ' + a.slice(0, 60)); fs.writeFileSync(p, s.replace(a, b)); };
const S = 'docs/human-mirror/DEVELOPMENT_STATUS.md', K = 'docs/human-mirror/KNOWN_ISSUES.md';
rep(S, 'fixes 1 and 14 of 15 done; fix 2 built, not applied or committed; fixes 3-13 and 15 open (list in KNOWN_ISSUES.md, P2-02 to P2-15)',
       'fixes 1, 2 and 14 of 15 done; fixes 3-13 and 15 open (list in KNOWN_ISSUES.md, P2-03 to P2-15)');
rep(S, '### 11/13/2026 — Phase 2 fix 14 of 15 DONE (migration 20261119266000)',
`### 11/13/2026 — Phase 2 fix 2 of 15 DONE (commit a69df77, migration 20261119265000)
- Built by an earlier session (idle since 00:34); taken over and finished by this one at Stephen's request.
- Read against live first: consents columns and checks, mirror.coordinates / my_role / me / audit exist; the live mirror_my_settings body was
  unchanged by later migrations, so the new body is the old one plus \`sharing_detail\`. Check p2-fix02 (rolled back) 5/5.
- Gap closed before shipping: the migration promised Settings would show "recorded by ..., on paper" but no page displayed it.
  /mirror/my-mirror/settings/ now shows "Recorded for you by <name>, on paper / out loud, on <date>. You can change it here."
- Live: consents.method + note, mirror_consent_record, mirror_consents_recorded, new settings body; 0 consents rows (nothing recorded yet);
  /mirror/workspace/person/ 200 and noindex, People list "Open their Mirror", Settings text present. Inline scripts pass node --check.
- Not done: a signed-in browser run of the coordinator page (needs Stephen's sign-in and authenticator).

### 11/13/2026 — Phase 2 fix 14 of 15 DONE (migration 20261119266000)`);
rep(S, '- Open: fixes 2 (built, not applied), 3-13, 15.', '- Open: fixes 3-13, 15 (fix 2 since done, see above).');
rep(K, 'Done: fix 1 (invitations accepted on My Mirror, commit 2face2e) and fix 14',
       'Done: fix 1 (invitations accepted on My Mirror, commit 2face2e), fix 2 (sharing choice recorded on paper or out loud for a person with no email, commit a69df77) and fix 14');
rep(K, '| P2-02 | People with no email are a dead end: no way to record a sharing choice given on paper or out loud. | Built (migration 20261119265000, check p2-fix02, page /mirror/workspace/person/); not committed, not applied. |\n', '');
console.log('ok');
