// Phase 10 step 32 doc updates (one-off; not committed).
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["  people; the refusal logged once; old counts expire). All Mirror checks run with and without the migration (results below).",
   "  people; the refusal logged once; old counts expire). All Mirror checks run with and without the migration (results below).\n\n" +
   "### 11/13/2026 — Phase 10 step 32: accessibility, phone, page weight, error handling (Stephen: \"go\")\n" +
   "- Browser pass (headless Chrome, signed out, live site): all 83 Mirror pages at phone width (390 px, touch) and desktop, 166 loads:\n" +
   "  axe-core WCAG 2.2 AA 0 violations; no page scrolls sideways on the phone; 0 script errors; keyboard focus visible on every stop\n" +
   "  tested (up to 30 Tab stops a page). 70 pages are signed-in pages and show the sign-in page when signed out, so for those the\n" +
   "  browser checks cover the sign-in page; their own markup is covered by the rules below, the real signed-in walk is the Guided Tour (D-28).\n" +
   "- Page weight: first visit about 126 KB with the fonts; later pages 7-41 KB. Calls: signed-in pages load up to 55 small files\n" +
   "  (the page and its modules; HTTP/2, cached 4 hours, K-05) before sign-in is checked; acceptable, noted for later.\n" +
   "- html-validate with the recommended and accessibility rules on every page: fixed 10 phone numbers that could break across lines\n" +
   "  (accessibility, forgot-password, privacy, sign-in) and 3 inputs without a type (daily-number, styleguide); now 0 problems.\n" +
   "- Error handling: all 202 database calls in the Mirror's page code are in a try block or check the returned error; none unhandled.\n" +
   "- Open: the signed-in screens in a real browser, Android, iPhone, Speak / Read aloud and Narrator stay the Guided Tour (D-28)."],
]);
edit("docs/human-mirror/MASTER_ROADMAP.md", [
  ["P2-15 rate limits, D-43, done 11/13/2026)", "P2-15 rate limits, D-43, and step 32 accessibility / phone / weight / errors (automated) done 11/13/2026)"],
]);
edit("docs/human-mirror/NEXT_ACTIONS.md", [
  ["P2-15 rate limits done (D-43); next the security review (step 31, after Phase 9 lands) or the accessibility, phone and performance pass (step 32).",
   "P2-15 rate limits done (D-43); step 32 automated pass done (0 axe violations, 0 overflow, 0 script errors); next deployment docs (step 35) and the security review (step 31, after Phase 9 lands)."],
]);
