// Print, for each function in a supa-query JSON ([{proname, prosrc}]), the text around each match of a pattern.
// Usage: node .claude-tools/ctx-grep.mjs <file.json> <regex> [chars]
import fs from "node:fs";
const rows = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const re = new RegExp(process.argv[3], "gi");
const w = Number(process.argv[4] || 160);
for (const r of rows) {
  const s = r.prosrc.replace(/\s+/g, " ");
  console.log("== " + r.proname);
  for (const m of s.matchAll(re)) console.log("   ..." + s.slice(Math.max(0, m.index - 40), m.index + w) + "...");
}
