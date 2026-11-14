// T8.7 page edits (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
const m = "site/mirror/assets/workspace-person.js";
let s = fs.readFileSync(m, "utf8");
if (s.includes("export async function receivedBox")) { console.error("already added"); process.exit(1); }
s = s.replace("; T8.6 benefits.", "; T8.6 benefits; T8.7 donated goods given.");
fs.writeFileSync(m, s.trimEnd() + "\n" + fs.readFileSync(process.argv[2], "utf8"));
console.log("ok " + m);
edit("site/mirror/workspace/person/index.html", [
  ['import { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox, appointmentsBox, notesBox, benefitsBox } from "/mirror/assets/workspace-person.js?v=20261113d";',
   '// T8.7 (11/13/2026): donated goods given\nimport { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox, appointmentsBox, notesBox, benefitsBox, receivedBox } from "/mirror/assets/workspace-person.js?v=20261113e";'],
  ['<a href="#oServices">Services</a><a href="#oBenefits">Benefits</a>', '<a href="#oServices">Services</a><a href="#oGiven">Things given</a><a href="#oBenefits">Benefits</a>'],
  ['    <section id="oBenefits">', '    <section id="oGiven"><h2>Things given</h2><div id="mmGiven"><p role="status">Loading…</p></div></section>\n    <section id="oBenefits">'],
  ['  benefitsBox(box.querySelector("#mmBenefits"), id, org, person.preferred_name);',
   '  receivedBox(box.querySelector("#mmGiven"), id, org, person.preferred_name);\n  benefitsBox(box.querySelector("#mmBenefits"), id, org, person.preferred_name);'],
]);
edit("site/mirror/workspace/index.html", [
  [`    \${orgs.length ? '<a class="mm-btn mm-btn-secondary" href="/mirror/workspace/services/">Our services</a>' : ""}\n`,
   `    \${orgs.length ? '<a class="mm-btn mm-btn-secondary" href="/mirror/workspace/services/">Our services</a>' : ""}\n    \${orgs.length ? '<a class="mm-btn mm-btn-secondary" href="/mirror/workspace/inventory/">Donated goods</a>' : ""}\n`],
]);
edit("site/mirror/my-mirror/services/index.html", [
  ['  let E;\n  try { E = await rpc("mirror_enrollments"); }',
   '  let E, G = { received: [] };\n  try { E = await rpc("mirror_enrollments"); }'],
  ['  const card = (x) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-enr="${esc(x.id)}">',
   '  try { G = await rpc("mirror_received"); } catch { G = { received: [] }; }   // T8.7: things I received\n  const card = (x) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-enr="${esc(x.id)}">'],
  ['    <p class="mm-small mm-muted mm-read">A service in a private part of life',
   '    <h2>Things I received</h2>\n    ${G.received.length ? `<ul style="padding-left:1.2rem">${G.received.map((g) => `<li>${esc(day(g.given_on))}: ${g.quantity} × ${esc(g.item)}${g.size ? " (" + esc(g.size) + ")" : ""}, from ${esc(g.organization)}${g.note ? ": " + esc(g.note) : ""}${g.returned ? \' <span class="mm-tag">Taken off: recorded by mistake</span>\' : ""}</li>`).join("")}</ul>`\n      : \'<p class="mm-muted">Nothing yet. Clothing, furniture and other donated items an organization gives you show here.</p>\'}\n    <p class="mm-small mm-muted mm-read">A service in a private part of life'],
]);
edit("site/mirror/my-mirror/settings/index.html", [
  ['      data.appointments = await rpc("mirror_my_export_appointments");     // T8.5: my appointments and the notes organizations wrote about me\n',
   '      data.appointments = await rpc("mirror_my_export_appointments");     // T8.5: my appointments and the notes organizations wrote about me\n      data.received = await rpc("mirror_my_export_received");             // T8.7: donated goods organizations gave me\n'],
  ['    d.appointments = await rpc("mirror_my_export_appointments"); } catch (e) { toast(e.message); return; }',
   '    d.appointments = await rpc("mirror_my_export_appointments"); d.received = await rpc("mirror_my_export_received"); } catch (e) { toast(e.message); return; }'],
  ['    ${d.services.length ? `<h2>My services</h2>',
   '    ${d.received.length ? `<h2>Things I received</h2><ul>${d.received.map((x) => `<li>${esc(x.given_on)}: ${esc(x.quantity)} × ${esc(x.item)}${x.size ? " (" + esc(x.size) + ")" : ""}, from ${esc(x.organization)}${x.returned ? " (taken off: recorded by mistake)" : ""}</li>`).join("")}</ul>` : ""}\n    ${d.services.length ? `<h2>My services</h2>'],
  ["the services you get, your appointments,", "the services you get, the things you received, your appointments,"],
]);
