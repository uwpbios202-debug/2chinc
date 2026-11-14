// Extracts each <script type="module"> body from an HTML file and syntax-checks it with node --check (imports are not resolved).
import fs from "node:fs"; import { execFileSync } from "node:child_process"; import os from "node:os"; import path from "node:path";
const html = fs.readFileSync(process.argv[2], "utf8");
const re = /<script type="module">([\s\S]*?)<\/script>/g; let m, i = 0, bad = 0;
while ((m = re.exec(html))) {
  const f = path.join(os.tmpdir(), `inline-${process.pid}-${i++}.mjs`); fs.writeFileSync(f, m[1]);
  try { execFileSync(process.execPath, ["--check", f], { stdio: "pipe" }); console.log(`module ${i}: ok`); }
  catch (e) { bad++; console.log(`module ${i}: ERROR\n${e.stderr}`); } finally { fs.rmSync(f); }
}
process.exit(bad ? 1 : 0);
