import fs from "node:fs";
const ed = (p, a, b) => { const s = fs.readFileSync(p, "utf8"); if (!s.includes(a)) throw new Error(p + ": " + a.slice(0, 80)); fs.writeFileSync(p, s.replace(a, b)); };
const D = "docs/human-mirror/DECISIONS.md";
// the two D-33 rows: label them apart, close both
ed(D, "| D-33 | **Landlord Recruitment Database (11/13/2026", "| D-33 (landlords) | **Landlord Recruitment Database (11/13/2026");
ed(D, "(c) a Navigator sees only her own outreach entries", "(c) a Navigator sees only their own outreach entries");
ed(D, "Do-Not-Partner, large networks and \"Screen first\" block sign-up. | DEFAULT (Stephen can change) |",
  "Do-Not-Partner, large networks and \"Screen first\" block sign-up. | DECIDED 11/14/2026 (Stephen: \"close those decisions using best logic\"; kept as built) |");
ed(D, "| D-33 | **Referrals with consent (T7.3", "| D-33 (referrals) | **Referrals with consent (T7.3");
ed(D, "(f) no new email kind (only the existing office notice in chpms_referral_save). | DEFAULT (confirm) |",
  "(f) no new email kind (only the existing office notice in chpms_referral_save). | DECIDED 11/14/2026 (Stephen: \"close those decisions using best logic\"; kept as built) |");
ed(D, "Migration 20261119695000. | DEFAULT, waiting for Stephen |", "Migration 20261119695000. | DECIDED 11/14/2026 (Stephen: \"close those decisions using best logic\"; kept as built) |");
ed(D, "Migration 20261119696000. | DEFAULT, waiting for Stephen |", "Migration 20261119696000. | DECIDED 11/14/2026 (Stephen: \"close those decisions using best logic\"; kept as built) |");
// launch order
const L = fs.readFileSync(D, "utf8").split("\n"); const i = L.findIndex((l) => l.startsWith("| D-45 |"));
L.splice(i + 1, 0, "| D-46 | **Launch order (Stephen 11/14/2026).** (1) Finish the build; (2) the Guided Tour (D-28): `mirror_signin_enabled` is switched on ONLY for the tour, with Stephen's trial Mirror and test data, no real person invited, and back off after it; (3) Supabase Pro (K-03: \"we will get Pro after the final walkthrough of the full system\"); (4) the privacy assessment and the final privacy page text from legal (K-04: \"Legal is working on it, so we wait for them\"); (5) launch: Stephen switches sign-in on for good and the first real person is invited (\"when we are complete and the walkthrough done\"). No real person's records go into the Mirror before (3) and (4). The Mirror email kinds are turned on at launch, after P10-01 is fixed. | DECIDED 11/14/2026 |");
fs.writeFileSync(D, L.join("\n"));
// known issues
const K = "docs/human-mirror/KNOWN_ISSUES.md";
ed(K, "| Decide before any real person uses the Mirror (Phase 10). |", "| DECIDED 11/14/2026 (Stephen): Supabase Pro after the final walkthrough (Guided Tour), before any real person (D-46). |");
ed(K, "Assessment by a qualified person before launch. |", "Assessment by a qualified person before launch. 11/14/2026: legal is working on it; we wait for them (D-46). |");
// deployment launch section
const P = "docs/human-mirror/DEPLOYMENT.md";
ed(P, "## 6. Before the launch (handoff steps 33-37)\n", "## 6. Before the launch (handoff steps 33-37; order decided by Stephen 11/14/2026, D-46)\n\nOrder: Guided Tour, then Supabase Pro, then legal's privacy text, then the launch.\n");
ed(P, "Stephen decides; until then there is no\n   daily backup of Mirror records.", "Stephen: Pro after the final walkthrough\n   (Guided Tour), before any real person; until then there is no daily backup of Mirror records.");
ed(P, "the final text of https://2ndchinc.org/mirror/privacy/. The site never claims compliance.", "the final text of https://2ndchinc.org/mirror/privacy/. The site never claims compliance. Legal is working on it (11/14/2026).");
ed(P, "4. **Launch:** Stephen switches `mirror_signin_enabled` on;", "4. **Launch** (after 1, 2 and 5): Stephen switches `mirror_signin_enabled` on for good and invites the first real person;");
ed(P, "and Edge, and Narrator. Not before the launch.", "and Edge, and Narrator. Comes FIRST: the switch is on only for the tour (Stephen's trial Mirror, no real person invited) and off again after.");
// next actions
ed("docs/human-mirror/NEXT_ACTIONS.md", "5. Before any real person: K-03 backups decision, K-04 privacy assessment, Stephen's launch go-ahead.",
  "5. Before any real person (order D-46, Stephen 11/14/2026): Guided Tour (switch on only for it), then Supabase Pro (K-03), then legal's privacy text (K-04), then launch.");
// local handoff
const H = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt";
ed(H, "33.   Backup and recovery plan: K-03 decision (daily backups need Supabase Pro) - Stephen decides.", "33.   [DECIDED 11/14/2026, D-46] Backup and recovery plan: K-03: Supabase Pro after the final walkthrough (step 37), before any real person.");
ed(H, "34.   Privacy: K-04", "34.   [WAITING FOR LEGAL 11/14/2026, D-46] Privacy: K-04");
ed(H, "36.   Launch decision by Stephen: switch mirror_signin_enabled on.", "36.   Launch by Stephen (D-46): AFTER the Guided Tour, Supabase Pro and legal's privacy text: switch sign-in on for good, invite the first real person.");
ed(H, "      Narrator. Not before step 36.", "      Narrator. Comes before step 36 (D-46): the switch is on only for the tour, Stephen's trial Mirror, no real person; off again after.");
console.log("ok");
