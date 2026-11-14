import fs from "node:fs";
const ed = (f, a, b) => { let s = fs.readFileSync(f, "utf8"); if (s.split(a).length !== 2) { console.log("MISS", f, a.slice(0, 60)); return; } fs.writeFileSync(f, s.replace(a, b)); console.log("ok", f); };
ed("docs/human-mirror/MASTER_ROADMAP.md", "loaded with the same verification rules. Deps: T7.1.",
  "loaded with the same verification rules. Deps: T7.1. Status: BUILT + LIVE 11/13/2026 (migrations 20261119630000 + 20261119631000, check tn3 5/5): Find help has a Life area filter (all 15 areas) on https://2ndchinc.org/staff/resources/ and the Navigator Resources tab; each program shows its life areas; office staff tag programs (office links, kept through every refresh). Researched from official pages 11/13: 7 new organizations and 10 programs (State ID, birth certificate, FoodShare, Hunger Task Force food, Progressive CHC care, Lifeline, library computers, Employ Milwaukee, Literacy Services, Job Center of Wisconsin); legal help was already listed. Show > \"Added 11/13 beyond housing\" lists them.");
ed("docs/human-mirror/NAVIGATOR.md", "plus research of non-housing programs (ID, health, food, phone, work, education, legal). |",
  "plus research of non-housing programs (ID, health, food, phone, work, education, legal). BUILT 11/13/2026 (migrations 20261119630000, 20261119631000). |");
ed("docs/BUG-CHECK-ROTATION.md", "tn2 still 6/6 (rolled back).",
  "tn2 still 6/6 (rolled back). TN.3 (migrations 20261119630000 + 631000): tn3 still 5/5 (rolled back); every program with import_version 'tn3-11/13' has an office life-area link and cites sources that exist; Find help shows the Life area filter (chpms.js?v=20261113a on /staff/resources/ and /navigator/). The 10 TN.3 programs were researched 11/13/2026: re-check their official pages when segment 9 or 11 runs (call before you refer).");
let s = fs.readFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", "utf8");
s = s.trimEnd() + `

### 11/13/2026 — Phase N step 20, TN.3: the directory by life area + non-housing programs (Stephen: "go")
- Migration 20261119630000_chpms_life_areas.sql: chpms_life_areas (the 15 areas and each program's areas, same access as the directory),
  chpms_program_areas_save (office staff tag a program; areas from its help types stay). chpms_directory unchanged.
- Migration 20261119631000_chpms_non_housing_programs.sql: researched 11/13/2026 from each program's own official page (sources TN3-S01..S10):
  new organizations DMV, Hunger Task Force, Progressive Community Health Centers, Lifeline (USAC), Milwaukee Public Library, Employ Milwaukee,
  Literacy Services of Wisconsin, Job Center of Wisconsin; programs: Wisconsin ID card (free for voting), certified birth certificate and FoodShare
  (at Wisconsin DHS, already listed), free food map and Senior Stockbox, sliding-fee health care, Lifeline discount, library computers and card,
  job and training programs, free adult education, job search. 9 Verified – Current, 1 Verified – Limited (Job Center: no phone, no operator named).
  Not added: the Milwaukee County Register of Deeds and City vital records pages refused automated reading (403), so they are only a note.
  Legal help was already in the directory with the legal life area.
- Page: Find help on https://2ndchinc.org/staff/resources/ and the Navigator Resources tab (chpms.js ?v=20261113a): Life area filter, "Life areas"
  on each program, "Change life areas" for office staff, Show > "Added 11/13 beyond housing".
- Checks: tn3 5/5 rolled back with both migrations (a food need in the Mirror is matched to 2 of the new programs); all 32 Mirror checks and t73 pass.
`;
fs.writeFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", s + "\n"); console.log("ok status");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("20.   TN.3 Directory by life area", "20.   [DONE 11/13/2026, migrations 20261119630000 + 631000] TN.3 Directory by life area"); fs.writeFileSync(h, t); console.log("ticked");
