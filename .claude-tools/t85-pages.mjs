// T8.5 page edits (one-off; not committed)
import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 100)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
edit("site/mirror/workspace/person/index.html", [
  ['import { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox } from "/mirror/assets/workspace-person.js?v=20261113b";',
   '// T8.5 (11/13/2026): appointments and contact notes\nimport { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox, appointmentsBox, notesBox } from "/mirror/assets/workspace-person.js?v=20261113c";'],
  ['<a href="#oPlan">Plan</a><a href="#oServices">Services</a>', '<a href="#oAppts">Appointments</a><a href="#oNotes">Notes</a><a href="#oPlan">Plan</a><a href="#oServices">Services</a>'],
  ['    <section id="oServices">',
   '    <section id="oAppts"><h2>Appointments with your organization</h2><div id="mmAppts"><p role="status">Loading…</p></div></section>\n    <section id="oNotes"><h2>Contact notes</h2><p class="mm-small mm-muted">Visits, calls and messages with them. They see every note.</p><div id="mmNotes"><p role="status">Loading…</p></div></section>\n    <section id="oServices">'],
  ['  servicesBox(box.querySelector("#mmServices"), id, org, person.preferred_name);',
   '  appointmentsBox(box.querySelector("#mmAppts"), id, org, person.preferred_name);\n  notesBox(box.querySelector("#mmNotes"), id, org, person.preferred_name);\n  servicesBox(box.querySelector("#mmServices"), id, org, person.preferred_name);'],
]);
edit("site/mirror/workspace/index.html", [
  ['  let D;\n  try { D = await rpc("mirror_workspace_dashboard", { p_org: org }); }',
   '  let D, AP = null;\n  try { D = await rpc("mirror_workspace_dashboard", { p_org: org }); }'],
  ['  const P = D.people;\n',
   '  // T8.5: appointments today and the next 7 days (the dashboard still works without them)\n  try { AP = await rpc("mirror_workspace_appointments", { p_org: org }); } catch { AP = null; }\n  const at = (t) => new Date(t).toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });\n  const isToday = (t) => new Date(t).toDateString() === new Date().toDateString();\n  const appts = !AP ? \'<p class="mm-muted">Appointments could not be loaded.</p>\' : AP.appointments.length ? `<ul class="mm-read" style="padding-left:1.2rem">${AP.appointments.map((a) => `<li style="margin-bottom:var(--mm-space-2)">\n      <strong>${esc(at(a.starts_at))}</strong>${isToday(a.starts_at) ? " " + tag("Today", "mm-tag-ok") : ""}: ${personLink(a)}, ${esc(a.title)}${a.place ? ` <span class="mm-muted mm-small">(${esc(a.place)})</span>` : ""}${a.private ? " " + tag("Private", "mm-tag-info") : ""}</li>`).join("")}</ul>`\n    : \'<p class="mm-muted">No appointments today or in the next 7 days.</p>\';\n  const P = D.people;\n'],
  ['    <h2>Appointments today</h2><p class="mm-muted">Appointments come with the next part of the workspace.</p>` + links;',
   '    <h2>Appointments today and this week${AP ? ` (${AP.appointments.length})` : ""}</h2>${appts}` + links;'],
]);
edit("site/mirror/my-mirror/index.html", [
  ['    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/services/">My services</a></p>',
   '    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/services/">My services</a></p>\n  <h2>My appointments</h2>\n  <p class="mm-read">Appointments with the organizations you work with, and your own (they stay yours). Also every note an organization writes about a visit or call with you.</p>\n  <p class="mm-row"><a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/appointments/">My appointments</a>\n    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/notes/">Notes about me</a></p>'],
]);
edit("site/mirror/my-mirror/settings/index.html", [
  ['      data.services = await rpc("mirror_my_export_services");             // T8.4: services I get from organizations, with their history\n',
   '      data.services = await rpc("mirror_my_export_services");             // T8.4: services I get from organizations, with their history\n      data.appointments = await rpc("mirror_my_export_appointments");     // T8.5: my appointments and the notes organizations wrote about me\n'],
  ['d.services = await rpc("mirror_my_export_services"); } catch (e) { toast(e.message); return; }',
   'd.services = await rpc("mirror_my_export_services");\n    d.appointments = await rpc("mirror_my_export_appointments"); } catch (e) { toast(e.message); return; }'],
  ['    ${d.services.length ? `<h2>My services</h2>',
   '    ${d.appointments.appointments.length ? `<h2>My appointments</h2><ul>${d.appointments.appointments.map((x) => `<li>${esc(new Date(x.starts_at).toLocaleString("en-US"))}: ${esc(x.title)}${x.organization ? ", with " + esc(x.organization) : " (my own)"}${x.place ? ", " + esc(x.place) : ""} (${esc({ scheduled: "coming up", done: "happened", cancelled: "cancelled", not_happened: "didn\'t happen" }[x.status] || x.status)})</li>`).join("")}</ul>` : ""}\n    ${d.appointments.notes_about_me.length ? `<h2>Notes about me</h2><ul>${d.appointments.notes_about_me.map((x) => `<li>${esc(new Date(x.at).toLocaleString("en-US"))}, ${esc(x.organization || "")} (${esc(x.by)}): ${esc(x.summary)}</li>`).join("")}</ul>` : ""}\n    ${d.services.length ? `<h2>My services</h2>'],
  ["the services you get, who you shared with, and who looked.", "the services you get, your appointments, the notes organizations wrote about you, who you shared with, and who looked."],
]);
