import fs from 'fs';
for (const f of process.argv.slice(2)) {
  const b = fs.readFileSync(f);
  if (b.toString('latin1', 0, 4) === '8BPS') {
    const ch = b.readUInt16BE(12), h = b.readUInt32BE(14), w = b.readUInt32BE(18), depth = b.readUInt16BE(22), mode = b.readUInt16BE(24);
    let p = 26; p += 4 + b.readUInt32BE(p); // color mode data
    const resLen = b.readUInt32BE(p); p += 4;
    let res = p; let dpi = '';
    while (res < p + resLen) { const id = b.readUInt16BE(res + 4); let nl = b[res + 6]; let q = res + 7 + nl; if ((nl + 1) % 2) q++; const sz = b.readUInt32BE(q); q += 4; if (id === 1005) dpi = (b.readUInt32BE(q) / 65536) + ' dpi'; res = q + sz + (sz % 2); }
    p += resLen;
    const lmLen = b.readUInt32BE(p); p += 4; const liLen = b.readUInt32BE(p); p += 4;
    let n = b.readInt16BE(p); p += 2; n = Math.abs(n);
    const names = [];
    for (let i = 0; i < n; i++) {
      const top = b.readInt32BE(p), left = b.readInt32BE(p + 4), bot = b.readInt32BE(p + 8), right = b.readInt32BE(p + 12); p += 16;
      const c = b.readUInt16BE(p); p += 2 + c * 6; p += 4 + 4; const opacity = b[p]; p += 4;
      const extra = b.readUInt32BE(p); p += 4; const e0 = p;
      const mLen = b.readUInt32BE(p); p += 4 + mLen; const bLen = b.readUInt32BE(p); p += 4 + bLen;
      const nl = b[p]; let name = b.toString('latin1', p + 1, p + 1 + nl);
      let q = p + 1 + nl; q += (4 - ((nl + 1) % 4)) % 4;
      while (q + 12 <= e0 + extra) { const sig = b.toString('latin1', q, q + 4), key = b.toString('latin1', q + 4, q + 8), len = b.readUInt32BE(q + 8);
        if (key === 'luni') { const cnt = b.readUInt32BE(q + 12); name = ''; for (let k = 0; k < cnt; k++) name += String.fromCharCode(b.readUInt16BE(q + 16 + 2 * k)); }
        if (sig !== '8BIM' && sig !== '8B64') break; q += 12 + len + (len % 2); }
      names.push(`${name} [${right - left}x${bot - top} at ${left},${top}]`);
      p = e0 + extra;
    }
    console.log(f, `PSD ${w}x${h}`, 'channels', ch, 'depth', depth, 'mode', mode, dpi, '\n  layers:', names.join('\n          '));
  } else if (b.toString('latin1', 1, 4) === 'PNG') {
    console.log(f, `PNG ${b.readUInt32BE(16)}x${b.readUInt32BE(20)}`, 'colortype', b[25], b[25] === 6 ? '(RGBA, has transparency)' : '(no alpha channel)');
  }
}
