import fs from "node:fs";
const f = "site/mirror/workspace/person/index.html";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) { console.error("MISSING: " + a); process.exit(1); } s = s.replace(a, b); };
rep('import { safetyBanner, needsBox, strengthsBox, planBox, progressBox } from "/mirror/assets/workspace-person.js?v=20261113a";',
    '// T8.4 (11/13/2026): services and enrollments\nimport { safetyBanner, needsBox, strengthsBox, planBox, progressBox, servicesBox } from "/mirror/assets/workspace-person.js?v=20261113b";');
rep('<a href="#oPlan">Plan</a><a href="#oStrengths">', '<a href="#oPlan">Plan</a><a href="#oServices">Services</a><a href="#oStrengths">');
rep('    <section id="oStrengths">', '    <section id="oServices"><h2>Services from your organization</h2><div id="mmServices"><p role="status">Loading…</p></div></section>\n    <section id="oStrengths">');
rep('  strengthsBox(box.querySelector("#mmStrengths"), id);', '  servicesBox(box.querySelector("#mmServices"), id, org, person.preferred_name);\n  strengthsBox(box.querySelector("#mmStrengths"), id);');
fs.writeFileSync(f, s);
console.log("ok");
