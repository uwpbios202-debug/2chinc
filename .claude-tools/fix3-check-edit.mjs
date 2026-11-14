import fs from 'node:fs';
const f = 'tools/mirror-checks/p2-fix03-link-needs-yes-check.sql';
let s = fs.readFileSync(f, 'utf8');
const before = s;
s = s.replace(/  ok := ok and \(select status from mirror\.organization_individuals where organization_id = (\w) and individual_id = (\w)\) = '(\w+)';\n/g,
  (m, o, i, st) => `  execute 'reset role';\n  ok := ok and (select status from mirror.organization_individuals where organization_id = ${o} and individual_id = ${i}) = '${st}';\n  perform set_config('role', 'authenticated', true);\n`);
if (s === before) throw new Error('no change');
fs.writeFileSync(f, s);
console.log((s.match(/execute 'reset role';\n  ok := ok and/g) || []).length, 'replaced');
