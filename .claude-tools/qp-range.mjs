import fs from 'fs';
const [src, from, to, out] = process.argv.slice(2);
const lines = fs.readFileSync(src, 'utf8').split(/\r?\n/).slice(Number(from), Number(to));
let s = lines.join('\n').replace(/=\n/g, '');
const bytes = [];
for (let i = 0; i < s.length; i++) {
  if (s[i] === '=' && /^[0-9A-F]{2}$/.test(s.substr(i + 1, 2))) { bytes.push(parseInt(s.substr(i + 1, 2), 16)); i += 2; }
  else for (const b of Buffer.from(s[i], 'utf8')) bytes.push(b);
}
fs.writeFileSync(out, Buffer.from(bytes).toString('utf8'));
console.log(out, Buffer.from(bytes).length);
