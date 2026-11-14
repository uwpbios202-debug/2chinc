// Minimal .eml reader: prints headers, attachment names, and decoded text of each message.
import fs from 'node:fs';
import path from 'node:path';

function qp(s) {
  const bytes = [];
  const t = s.replace(/=\r?\n/g, '');
  for (let i = 0; i < t.length; i++) {
    if (t[i] === '=' && /^[0-9A-F]{2}$/i.test(t.substr(i + 1, 2))) { bytes.push(parseInt(t.substr(i + 1, 2), 16)); i += 2; }
    else bytes.push(t.charCodeAt(i) & 0xff);
  }
  return Buffer.from(bytes).toString('utf8');
}
function headers(block) {
  const h = {};
  block.replace(/\r?\n[ \t]+/g, ' ').split(/\r?\n/).forEach((l) => {
    const m = l.match(/^([\w-]+):\s*(.*)$/); if (m) h[m[1].toLowerCase()] = m[2];
  });
  return h;
}
function decWord(s) {
  return (s || '').replace(/=\?([^?]+)\?([BQ])\?([^?]*)\?=/gi, (_, cs, enc, txt) =>
    enc.toUpperCase() === 'B' ? Buffer.from(txt, 'base64').toString('utf8') : qp(txt.replace(/_/g, ' ')));
}
function htmlToText(h) {
  return h.replace(/<(script|style)[\s\S]*?<\/\1>/gi, '')
    .replace(/<br\s*\/?>|<\/p>|<\/tr>|<\/div>|<\/li>|<\/h\d>/gi, '\n').replace(/<\/td>/gi, ' | ')
    .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/&quot;/g, '"').replace(/&#39;|&rsquo;/g, "'");
}
function walk(raw, out) {
  const i = raw.search(/\r?\n\r?\n/);
  const h = headers(raw.slice(0, i)); const body = raw.slice(i).replace(/^\r?\n\r?\n/, '');
  const ct = h['content-type'] || 'text/plain';
  const b = ct.match(/boundary="?([^";]+)"?/i);
  if (/^multipart/i.test(ct) && b) {
    body.split('--' + b[1]).slice(1).forEach((p) => { if (!p.startsWith('--')) walk(p.replace(/^\r?\n/, ''), out); });
    return;
  }
  const fn = (h['content-disposition'] || '').match(/filename="?([^";]+)"?/i) || ct.match(/name="?([^";]+)"?/i);
  const enc = (h['content-transfer-encoding'] || '').toLowerCase();
  if (fn && !/^text\//i.test(ct.split(';')[0]) || /attachment/i.test(h['content-disposition'] || '')) { out.att.push(decWord(fn ? fn[1] : '?') + ' (' + ct.split(';')[0] + ')'); return; }
  let txt = enc === 'base64' ? Buffer.from(body.replace(/\s+/g, ''), 'base64').toString('utf8') : enc === 'quoted-printable' ? qp(body) : body;
  if (/text\/html/i.test(ct)) { if (!out.plain) out.html = htmlToText(txt); } else if (/text\/plain/i.test(ct)) out.plain = txt;
}
for (const f of process.argv.slice(2)) {
  const raw = fs.readFileSync(f, 'latin1');
  const top = headers(raw.slice(0, raw.search(/\r?\n\r?\n/)));
  const out = { att: [] };
  walk(Buffer.from(raw, 'latin1').toString('latin1'), out);
  console.log('='.repeat(90));
  console.log('FILE:', path.basename(f));
  ['date', 'from', 'to', 'subject'].forEach((k) => console.log(k + ':', decWord(top[k])));
  out.att.forEach((a) => console.log('ATTACHMENT:', a));
  const text = (out.plain || out.html || '').replace(/[ \t ]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim();
  console.log(text.slice(0, 6000));
}
