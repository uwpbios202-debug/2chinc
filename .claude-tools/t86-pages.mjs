// T8.6 page edits (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const m = "site/mirror/assets/workspace-person.js";
let s = fs.readFileSync(m, "utf8");
if (s.includes("export async function benefitsBox")) { console.error("already added"); process.exit(1); }
s = s.replace("; T8.4 services; T8.5 appointments and contact notes.", "; T8.4 services; T8.5 appointments and contact notes; T8.6 benefits.");
fs.writeFileSync(m, s.trimEnd() + "\n" + fs.readFileSync(process.argv[2], "utf8"));
console.log("ok " + m);
edit("site/mirror/workspace/person/index.html", [
  ['import { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox, appointmentsBox, notesBox } from "/mirror/assets/workspace-person.js?v=20261113c";',
   '// T8.6 (11/13/2026): benefits applications\nimport { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox, appointmentsBox, notesBox, benefitsBox } from "/mirror/assets/workspace-person.js?v=20261113d";'],
  ['<a href="#oServices">Services</a>', '<a href="#oServices">Services</a><a href="#oBenefits">Benefits</a>'],
  ['    <section id="oStrengths">', '    <section id="oBenefits"><h2>Benefits and applications</h2><p class="mm-small mm-muted">Private (Money): shown only if they share it with you.</p><div id="mmBenefits"><p role="status">Loading…</p></div></section>\n    <section id="oStrengths">'],
  ['  servicesBox(box.querySelector("#mmServices"), id, org, person.preferred_name);',
   '  servicesBox(box.querySelector("#mmServices"), id, org, person.preferred_name);\n  benefitsBox(box.querySelector("#mmBenefits"), id, org, person.preferred_name);'],
]);
edit("site/mirror/workspace/index.html", [
  ['  try { AP = await rpc("mirror_workspace_appointments", { p_org: org }); } catch { AP = null; }\n',
   '  try { AP = await rpc("mirror_workspace_appointments", { p_org: org }); } catch { AP = null; }\n  // T8.6: benefit renewals and appeal deadlines (people who share Money with you)\n  let BD = null;\n  try { BD = await rpc("mirror_benefit_dates", { p_org: org }); } catch { BD = null; }\n  const bens = !BD ? \'<p class="mm-muted">Benefit dates could not be loaded.</p>\' : BD.dates.length ? `<ul class="mm-read" style="padding-left:1.2rem">${BD.dates.map((b) => `<li style="margin-bottom:var(--mm-space-2)">\n      <strong>${esc(day(b.on))}</strong>: ${personLink(b)}, ${esc(b.program)}: ${b.what === "appeal" ? "last day to appeal" : b.passed ? "renewal date passed" : "renewal due"}${b.what === "appeal" || b.passed ? " " + tag("Act now", "mm-tag-urgent") : ""}</li>`).join("")}</ul>`\n    : \'<p class="mm-muted">No renewals or appeal deadlines in the next 30 days.</p>\';\n'],
  ['    <h2>Appointments today and this week${AP ? ` (${AP.appointments.length})` : ""}</h2>${appts}` + links;',
   '    <h2>Appointments today and this week${AP ? ` (${AP.appointments.length})` : ""}</h2>${appts}\n    <h2>Benefit renewals and appeal deadlines${BD ? ` (${BD.dates.length})` : ""}</h2>\n    <p class="mm-small mm-muted mm-read">Renewals due in the next 30 days or already passed, and appeal deadlines in the next 30 days. Only for people who share Money with you.</p>${bens}` + links;'],
]);
