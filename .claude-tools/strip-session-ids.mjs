import fs from 'node:fs';
const files = process.argv.slice(2);
let total = 0;
for (const f of files) {
  const s = fs.readFileSync(f, 'utf8');
  const parts = s.split(", 'session_id', gen_random_uuid()");
  if (parts.length > 1) { fs.writeFileSync(f, parts.join('')); total += parts.length - 1; console.log(parts.length - 1, f); }
}
console.log('total', total);
