import fs from 'node:fs';
const sp = 'docs/human-mirror/DEVELOPMENT_STATUS.md';
let s = fs.readFileSync(sp, 'utf8');
const oldRows = `| 2 Database and access control | DONE 11/13/2026 (except the invitation email, Phase 9) | |
| 4 Daily Number | DONE 11/13/2026 | T4.1-T4.4; 45 hand-worked figures match in JS and SQL. |
| 3 Individual Mirror | DONE 11/13/2026 | T3.1-T3.6; 23 question sets, 244 questions; hands-free (D-23). |
| 3-10 | LATER | |`;
const newRows = `| 2 Database and access control | IN PROGRESS | T2.1-T2.5 live. Deep-dive (11/13): fixes 1 and 14 of 15 done; fix 2 built, not applied or committed; fixes 3-13 and 15 open (list in KNOWN_ISSUES.md, P2-02 to P2-15). T2.6 half done: /mirror/register/ and the invitation email (Phase 9) still to do. |
| 3 Individual Mirror | DONE 11/13/2026 | T3.1-T3.6; 23 question sets, 244 questions; hands-free (D-23). |
| 4 Daily Number | DONE 11/13/2026 | T4.1-T4.4; 45 hand-worked figures match in JS and SQL. |
| 5-10 | LATER | |`;
if (!s.includes(oldRows)) throw new Error('status rows not found');
s = s.replace(oldRows, newRows);
fs.writeFileSync(sp, s);
const kp = 'docs/human-mirror/KNOWN_ISSUES.md';
let k = fs.readFileSync(kp, 'utf8');
if (k.includes('P2-02')) throw new Error('already added');
k = k.replace(/\n*$/, '\n') + `
## Phase 2 open fixes (deep-dive 11/13/2026; Stephen: one at a time)

Done: fix 1 (invitations accepted on My Mirror, commit 2face2e) and fix 14 (audit log cannot be emptied with TRUNCATE, commit 0fa1e53).

| # | Issue | Status |
|---|---|---|
| P2-02 | People with no email are a dead end: no way to record a sharing choice given on paper or out loud. | Built (migration 20261119265000, check p2-fix02, page /mirror/workspace/person/); not committed, not applied. |
| P2-03 | Adding a person by email links an existing Mirror without the person's yes. | Open |
| P2-04 | 2nd Chance admins can join any organization without anyone seeing it. | Open |
| P2-05 | The Mirror ignores \`session_fresh\`. | Open |
| P2-06 | The safety flag is not used. | Open |
| P2-07 | No organization or platform view of the audit log. | Open |
| P2-08 | Admin pages missing: teams, roles, consent, email, data. | Open |
| P2-09 | No deletion run after the 30 days. | Open |
| P2-10 | No process to change a person's email. | Open |
| P2-11 | No authenticator reset for coordinators outside 2nd Chance. | Open |
| P2-12 | Consent expiry cannot be set and there is no reminder. | Open |
| P2-13 | Access rules live in two places (permission matrix and admin functions). | Open |
| P2-15 | No rate limits. | Open |
| T2.6 | /mirror/register/ (accepting an invitation by link) not built; invitation email waits for Phase 9 and Stephen's wording. | Open |
`;
fs.writeFileSync(kp, k);
console.log('ok');
