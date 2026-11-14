// Prints the bounding box of every object mesh in a 3MF (or binary STL) file.
// Usage: node .claude-tools/bbox3mf.mjs <file> [<file> ...]
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

function walk(d) {
  return readdirSync(d).flatMap((f) => {
    const p = join(d, f);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}
function report(label, xs, ys, zs) {
  const r = (a) => [Math.min(...a), Math.max(...a)];
  const [x0, x1] = r(xs), [y0, y1] = r(ys), [z0, z1] = r(zs);
  console.log(`${label}: X ${(x1 - x0).toFixed(2)}  Y ${(y1 - y0).toFixed(2)}  Z ${(z1 - z0).toFixed(2)}  (${xs.length} verts)`);
}
for (const file of process.argv.slice(2)) {
  console.log('== ' + file);
  if (file.toLowerCase().endsWith('.stl')) {
    const b = readFileSync(file);
    const n = b.readUInt32LE(80);
    const xs = [], ys = [], zs = [];
    for (let i = 0; i < n; i++) {
      const o = 84 + i * 50 + 12;
      for (let v = 0; v < 3; v++) {
        xs.push(b.readFloatLE(o + v * 12));
        ys.push(b.readFloatLE(o + v * 12 + 4));
        zs.push(b.readFloatLE(o + v * 12 + 8));
      }
    }
    report('stl', xs, ys, zs);
    continue;
  }
  const dir = mkdtempSync(join(tmpdir(), 'bbox3mf-'));
  execFileSync('C:\\Windows\\System32\\tar.exe',['-xf', file, '-C', dir]);
  for (const p of walk(dir).filter((p) => p.endsWith('.model'))) {
    const txt = readFileSync(p, 'utf8');
    const objs = txt.split(/<object /).slice(1);
    for (const o of objs) {
      const id = (o.match(/id="(\d+)"/) || [])[1];
      const name = (o.match(/name="([^"]*)"/) || [])[1] || '';
      const xs = [], ys = [], zs = [];
      for (const m of o.matchAll(/<vertex x="([-\d.e]+)" y="([-\d.e]+)" z="([-\d.e]+)"/g)) {
        xs.push(+m[1]); ys.push(+m[2]); zs.push(+m[3]);
      }
      if (xs.length) report(`${p.slice(dir.length)} obj ${id} ${name}`, xs, ys, zs);
    }
  }
}
