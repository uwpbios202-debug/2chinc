import fs from 'fs'; import zlib from 'zlib';
for (const f of process.argv.slice(2)) {
  const b = fs.readFileSync(f); let p = 8, w, h, ct, idat = [];
  while (p < b.length) { const len = b.readUInt32BE(p), type = b.toString('latin1', p + 4, p + 8);
    if (type === 'IHDR') { w = b.readUInt32BE(p + 8); h = b.readUInt32BE(p + 12); ct = b[p + 17]; }
    if (type === 'IDAT') idat.push(b.subarray(p + 8, p + 8 + len)); p += 12 + len; }
  if (ct !== 6) { console.log(f, 'no alpha'); continue; }
  const raw = zlib.inflateSync(Buffer.concat(idat)), bpp = 4, stride = w * bpp;
  let prev = Buffer.alloc(stride), cur, clear = 0, solid = 0, partial = 0, lowA = 0, midA = 0;
  for (let y = 0; y < h; y++) { const ft = raw[y * (stride + 1)]; cur = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let x = 0; x < stride; x++) { const a = x >= bpp ? cur[x - bpp] : 0, up = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
      let v = cur[x]; if (ft === 1) v += a; else if (ft === 2) v += up; else if (ft === 3) v += (a + up) >> 1;
      else if (ft === 4) { const pp = a + up - c, pa = Math.abs(pp - a), pb = Math.abs(pp - up), pc = Math.abs(pp - c); v += (pa <= pb && pa <= pc) ? a : pb <= pc ? up : c; }
      cur[x] = v & 255; }
    for (let x = 3; x < stride; x += 4) { const al = cur[x]; if (al === 0) clear++; else if (al === 255) solid++; else { partial++; if (al <= 20) lowA++; else if (al < 235) midA++; } }
    prev = cur; }
  const t = w * h; console.log("low-alpha(1-20):", lowA, "mid(21-234):", midA); console.log(f, `${w}x${h}`, 'transparent', (100 * clear / t).toFixed(1) + '%', 'opaque', (100 * solid / t).toFixed(1) + '%', 'partly', (100 * partial / t).toFixed(1) + '%');
}
