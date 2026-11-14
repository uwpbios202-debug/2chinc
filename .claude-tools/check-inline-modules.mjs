// Extracts each page's inline <script type="module"> and syntax-checks it with node --check.
// Usage: node .claude-tools/check-inline-modules.mjs <page.html> [more pages...]
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "inl-"));
let bad = 0;
for (const page of process.argv.slice(2)) {
  const html = readFileSync(page, "utf8");
  const code = [...html.matchAll(/<script type="module">([\s\S]*?)<\/script>/g)].map((m) => m[1]).join("\n");
  const f = join(dir, "x.mjs");
  writeFileSync(f, code);
  try { execFileSync(process.execPath, ["--check", f], { stdio: "pipe" }); console.log("ok   " + page); }
  catch (e) { bad++; console.log("FAIL " + page + "\n" + String(e.stderr)); }
}
process.exit(bad ? 1 : 0);
