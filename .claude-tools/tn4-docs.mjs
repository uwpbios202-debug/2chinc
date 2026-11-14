import fs from "node:fs";
const ed = (f, a, b) => { let s = fs.readFileSync(f, "utf8"); if (s.split(a).length !== 2) { console.log("MISS", f, a.slice(0, 60)); return; } fs.writeFileSync(f, s.replace(a, b)); console.log("ok", f); };
ed("docs/human-mirror/MASTER_ROADMAP.md", "staff can list these matches. Deps: none (can be built in the live portal any time).",
  "staff can list these matches. Deps: none (can be built in the live portal any time). Status: BUILT + LIVE 11/13/2026 (migration 20261119640000, check tn4 6/6): \"A room you run\" on the file; the person types their full name to confirm the exact sentence; a trigger blocks the placement (approved) until then, and a different room needs a new confirmation; the office's Navigators dashboard lists every such match.");
ed("docs/human-mirror/NAVIGATOR.md", "and the person confirms on screen that they know and chose it. |",
  "and the person confirms on screen that they know and chose it. BUILT 11/13/2026 (migration 20261119640000). |");
const bf = "docs/BUG-CHECK-ROTATION.md"; let b = fs.readFileSync(bf, "utf8"); const a = "(call before you refer).";
if (b.split(a).length === 2) { b = b.replace(a, a + " TN.4 (migration 20261119640000): nav_own_room_confirms has row security and no anon/authenticated grants; trigger nav_referrals_own_room_guard exists; 0 non-sample files approved or moved in after 11/13/2026 to a home their Navigator runs without a confirmation for that unit and room (count only); tn4 still 6/6 (rolled back)."); fs.writeFileSync(bf, b); console.log("ok", bf); } else console.log("MISS bcr");
let s = fs.readFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", "utf8");
s = s.trimEnd() + `

### 11/13/2026 — Phase N step 21, TN.4: own-room disclosure (Stephen: "go")
- Migration 20261119640000_nav_own_room_disclosure.sql: table nav_own_room_confirms (row security, service_role only); nav_own_room (matched to a
  home the file's own Navigator runs), nav_own_room_state / nav_own_room_confirm (the person types their full name to the exact sentence: they
  know their Navigator runs the home, were told about other places, choose this one, can say no without losing help), trigger
  nav_referrals_own_room_guard (no placement, status approved, without the confirmation for that unit and room), nav_own_room_matches (office list).
  nav_referral_step unchanged. Only sample files are matched to a Navigator-run home today. No email.
- Pages: "A room you run" on the file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/ (nav-common.js ?v=20261113c);
  "Matches to rooms a Navigator runs" on the office's Navigators dashboard.
- Checks: tn4 6/6 rolled back; all 32 Mirror checks and tn2 pass with the migration.
`;
fs.writeFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md", s + "\n"); console.log("ok status");
const h = "Claude outputs/Human-Mirror-Remaining-Work-Handoff.txt"; let t = fs.readFileSync(h, "utf8");
t = t.replace("21.   TN.4 Own-room disclosure", "21.   [DONE 11/13/2026, migration 20261119640000] TN.4 Own-room disclosure"); fs.writeFileSync(h, t); console.log("ticked");
