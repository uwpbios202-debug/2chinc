// Read-only: for each session transcript, print the last 3 user prompts and the last assistant text.
import fs from 'node:fs';
import path from 'node:path';
const dir = process.argv[2];
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.jsonl'))) {
  const lines = fs.readFileSync(path.join(dir, f), 'utf8').split('\n').filter(Boolean);
  const users = [];
  let lastAsst = '';
  let lastTs = '';
  for (const l of lines) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.timestamp) lastTs = o.timestamp;
    const c = o.message && o.message.content;
    if (o.type === 'user' && !o.isMeta) {
      const t = typeof c === 'string' ? c : Array.isArray(c) ? c.filter((x) => x.type === 'text').map((x) => x.text).join(' ') : '';
      if (t && !t.startsWith('<') && !t.includes('tool_result')) users.push(t.slice(0, 300));
    }
    if (o.type === 'assistant' && Array.isArray(c)) {
      const t = c.filter((x) => x.type === 'text').map((x) => x.text).join(' ');
      if (t.trim()) lastAsst = t;
    }
  }
  console.log('=== ' + f + '  last activity ' + lastTs);
  for (const u of users.slice(-3)) console.log('  USER: ' + u.replace(/\s+/g, ' '));
  console.log('  LAST CLAUDE: ' + lastAsst.slice(0, 700).replace(/\s+/g, ' '));
}
