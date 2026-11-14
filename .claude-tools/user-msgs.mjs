import fs from 'fs';
const [file, pat, max] = process.argv.slice(2);
const re = new RegExp(pat, 'i');
for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
  if (!line.trim()) continue;
  let o; try { o = JSON.parse(line); } catch { continue; }
  if (o.type !== 'user' || !o.message) continue;
  const c = o.message.content;
  let t = typeof c === 'string' ? c : (Array.isArray(c) ? c.filter(x => x.type === 'text').map(x => x.text).join('\n') : '');
  if (!t || t.startsWith('<system') || t.includes('tool_use_id')) continue;
  if (re.test(t)) console.log('=== ' + (o.timestamp || '') + '\n' + t.slice(0, Number(max || 4000)) + '\n');
}
