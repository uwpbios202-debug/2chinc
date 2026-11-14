import fs from "node:fs";
const edit = (f, pairs) => {
  let s = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!s.includes(a)) { console.error("MISSING in " + f + ": " + a.slice(0, 90)); process.exit(1); } s = s.replace(a, b); }
  fs.writeFileSync(f, s); console.log("ok " + f);
};
edit("site/mirror/my-mirror/settings/index.html", [
  ['      data.documents = await rpc("mirror_my_export_documents");           // T7.4: my documents (details; the files open from My documents)\n',
   '      data.documents = await rpc("mirror_my_export_documents");           // T7.4: my documents (details; the files open from My documents)\n      data.services = await rpc("mirror_my_export_services");             // T8.4: services I get from organizations, with their history\n'],
  ['    d.documents = await rpc("mirror_my_export_documents"); } catch (e) { toast(e.message); return; }',
   '    d.documents = await rpc("mirror_my_export_documents"); d.services = await rpc("mirror_my_export_services"); } catch (e) { toast(e.message); return; }'],
  ['  const REF_STATUS = {', '  const SVC_STATUS = { active: "Getting it", paused: "On hold", completed: "Finished", ended: "Stopped" };\n  const REF_STATUS = {'],
  ['    ${d.referrals.length ? `<h2>My referrals</h2>',
   '    ${d.services.length ? `<h2>My services</h2><ul>${d.services.map((x) => `<li>${esc(x.service)}, from ${esc(x.organization || "")}: ${esc(SVC_STATUS[x.status] || x.status)}, since ${esc(x.started_on)}${x.ended_on ? " until " + esc(x.ended_on) : ""}${x.note ? ". " + esc(x.note) : ""}</li>`).join("")}</ul>` : ""}\n    ${d.referrals.length ? `<h2>My referrals</h2>'],
]);
edit("site/mirror/my-mirror/index.html", [
  ['    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/referrals/">My referrals</a></p>',
   '    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/referrals/">My referrals</a>\n    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/services/">My services</a></p>'],
]);
edit("site/mirror/workspace/index.html", [
  [`    \${orgs.length ? '<a class="mm-btn mm-btn-secondary" href="/mirror/workspace/assessments/">Questions together</a>' : ""}\n`,
   `    \${orgs.length ? '<a class="mm-btn mm-btn-secondary" href="/mirror/workspace/assessments/">Questions together</a>' : ""}\n    \${orgs.length ? '<a class="mm-btn mm-btn-secondary" href="/mirror/workspace/services/">Our services</a>' : ""}\n`],
]);
