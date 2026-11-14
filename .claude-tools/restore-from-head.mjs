import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
for (const f of process.argv.slice(2)) {
  const head = execFileSync('git', ['show', 'HEAD:' + f], { maxBuffer: 1 << 26 });
  fs.writeFileSync(f, head);
}
console.log('restored', process.argv.length - 2);
