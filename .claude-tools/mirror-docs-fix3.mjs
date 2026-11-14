import fs from 'node:fs';
const rep = (p, a, b) => { const s = fs.readFileSync(p, 'utf8'); if (!s.includes(a)) throw new Error('not found in ' + p + ': ' + a.slice(0, 70)); fs.writeFileSync(p, s.replace(a, b)); };
const S = 'docs/human-mirror/DEVELOPMENT_STATUS.md', K = 'docs/human-mirror/KNOWN_ISSUES.md';
rep(S, 'fixes 1, 2 and 14 of 15 done; fixes 3-13 and 15 open (list in KNOWN_ISSUES.md, P2-03 to P2-15)',
       'fixes 1, 2, 3 and 14 of 15 done; fixes 4-13 and 15 open (list in KNOWN_ISSUES.md, P2-04 to P2-15)');
rep(S, '### 11/13/2026 — Phase 2 fix 2 of 15 DONE (commit a69df77, migration 20261119265000)',
`### 11/13/2026 — Phase 2 fix 3 of 15 DONE (commit ca6c8f4, migration 20261119267000)
- Read on live first. Since fix 1 an invited person's answers were already closed; three gaps remained and are closed:
  1. mirror_person_status let a coordinator set ANY link to active (skipping the yes). Now active only for people with no email;
     invited only for people with an email.
  2. mirror_people showed an existing Mirror's own name, legal name, birth year and safety flag to an organization that had only
     invited them (or that they declined), which also revealed the email had a Mirror. Now, until the person accepts (audit
     invitation_accept) or unless the organization created the record (mirror.known_to_org), only the typed name
     (organization_individuals.invited_name) and the email show.
  3. mirror_person_add kept the typed name and answers the same whether the email had a Mirror or not.
- Check p2-fix03 (rolled back) 6/6; p2-fix01 4/4, t25 6/6, p2-fix02 5/5 still pass. No page change needed (People page already handles
  an empty legal name; the person page opens only active people).
- Applied ALONE: another session's uncommitted 20261119280000 and 20261119281000 were left out (they do not touch these functions).

### 11/13/2026 — Phase 2 fix 2 of 15 DONE (commit a69df77, migration 20261119265000)`);
rep(K, 'fix 2 (sharing choice recorded on paper or out loud for a person with no email, commit a69df77) and fix 14',
       'fix 2 (sharing choice recorded on paper or out loud for a person with no email, commit a69df77), fix 3 (linking an existing Mirror needs the person\'s yes and shows nothing of theirs before it, commit ca6c8f4) and fix 14');
rep(K, "| P2-03 | Adding a person by email links an existing Mirror without the person's yes. | Open |\n", '');
console.log('ok');
