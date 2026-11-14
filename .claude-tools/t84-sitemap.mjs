import fs from "node:fs";
const f = "docs/human-mirror/SITEMAP.md";
let s = fs.readFileSync(f, "utf8");
const a = "| referrals/ | My referrals: agree by typing my name";
const b = "| assessments/ | Review the questions gone over with each person";
if (!s.includes(a) || !s.includes(b)) { console.error("missing"); process.exit(1); }
let i = s.indexOf("\n", s.indexOf(a)) + 1;
s = s.slice(0, i) + "| services/ | My services: what I get from organizations I work with, its history, \"I stopped getting this\" (T8.4, D-34; built 11/13/2026) | 8 |\n" + s.slice(i);
i = s.indexOf("\n", s.indexOf(b)) + 1;
s = s.slice(0, i) + "| services/ | Our services: the organization's own list (admins add, change, retire); enroll from person/ (T8.4, D-34; built 11/13/2026) | 8 |\n" + s.slice(i);
fs.writeFileSync(f, s); console.log("ok");
