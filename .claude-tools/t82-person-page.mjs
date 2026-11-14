// T8.2: one-person overview sections on the workspace person page; safety tag on the people list. Each replace must match once.
import fs from "node:fs";
const edits = [
  ["site/mirror/workspace/person/index.html",
   `import { housingBox } from "/mirror/assets/housing-page.js?v=20261113p";`,
   `import { housingBox } from "/mirror/assets/housing-page.js?v=20261113p";
// Phase 8 T8.2 (11/13/2026): the one-person overview: safety note (P2-06), needs, strengths, plan, progress
import { safetyBanner, needsBox, strengthsBox, planBox, progressBox } from "/mirror/assets/workspace-person.js?v=20261113a";`],
  ["site/mirror/workspace/person/index.html",
   `    <p class="mm-lead">\${canEdit ? "You can fill in their Mirror together." : "You can see their answers in general."} Private topics open only as they choose.</p>`,
   `    <p class="mm-lead">\${canEdit ? "You can fill in their Mirror together." : "You can see their answers in general."} Private topics open only as they choose.</p>
    \${person.safety_sensitive ? safetyBanner(person.preferred_name) : ""}
    <nav aria-label="On this page" class="mm-small mm-row" style="gap:var(--mm-space-3);margin-bottom:var(--mm-space-4)">
      <a href="#oNeeds">Needs</a><a href="#oPlan">Plan</a><a href="#oStrengths">Strengths</a><a href="#oProgress">Progress</a><a href="#oShare">What they share</a><a href="#oMirror">Their answers</a></nav>
    <section id="oNeeds"><h2>Needs</h2><div id="mmNeeds"><p role="status">Loading…</p></div></section>
    <section id="oPlan"><h2>Plan</h2><div id="mmPlan"><p role="status">Loading…</p></div></section>
    <section id="oStrengths"><h2>Strengths</h2><div id="mmStrengths"><p role="status">Loading…</p></div></section>
    <section id="oProgress"><h2>Progress</h2><p class="mm-small mm-muted">Counts only, never a score, and only for the parts of life they share with you.</p><div id="mmProgress"><p role="status">Loading…</p></div></section>`],
  ["site/mirror/workspace/person/index.html",
   `    <section class="mm-card mm-read" style="margin-bottom:var(--mm-space-5)">
      <h2 style="margin-top:0">What`,
   `    <section class="mm-card mm-read" style="margin-bottom:var(--mm-space-5)" id="oShare">
      <h2 style="margin-top:0">What`],
  ["site/mirror/workspace/person/index.html",
   `    <section><h2>Their Mirror</h2>`,
   `    <section id="oMirror"><h2>Their Mirror</h2>`],
  ["site/mirror/workspace/person/index.html",
   `  if (rec.can_record) wireRecord();
  sets();`,
   `  if (rec.can_record) wireRecord();
  needsBox(box.querySelector("#mmNeeds"), id, person.preferred_name);
  planBox(box.querySelector("#mmPlan"), id);
  strengthsBox(box.querySelector("#mmStrengths"), id);
  progressBox(box.querySelector("#mmProgress"), id);
  sets();`],
  ["site/mirror/workspace/people/index.html",
   `        <td data-label="Name"><strong>\${esc(p.preferred_name)}</strong>`,
   `        <td data-label="Name"><strong>\${esc(p.preferred_name)}</strong>\${p.safety_sensitive ? ' <span class="mm-tag mm-tag-urgent">Safety mode</span>' : ""}`],
];
for (const [f, a, b] of edits) {
  const t = fs.readFileSync(f, "utf8");
  const k = t.split(a).length - 1;
  if (k !== 1) { console.log("FAIL (" + k + "): " + f + " :: " + a.slice(0, 70)); process.exit(1); }
  fs.writeFileSync(f, t.replace(a, () => b));
}
console.log("ok " + edits.length);
