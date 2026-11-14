// For each "file:ENTRY-ID", prints the links (href) inside that entry's block of the audit (read-only; leads to verify).
import fs from "node:fs";
const dir = "Issues and fixes/Databases_TheMirror/";
const cache = {};
for (const arg of process.argv.slice(2)) {
  const [f, id] = arg.split(":");
  const html = (cache[f] ??= fs.readFileSync(dir + "Milwaukee_" + f + "_Folder_Audit.html", "utf8"));
  const i = html.indexOf(id + " · ");
  if (i < 0) { console.log(id, "NOT FOUND"); continue; }
  const next = html.slice(i + 20).search(/[A-Z]{2,6}-[A-Z]{1,4}-\d{3} · /);
  const block = html.slice(i, next > 0 ? i + 20 + next : i + 15000);
  const urls = [...new Set([...block.matchAll(/href="(https?:[^"]+)"/g)].map((m) => m[1].replace(/&amp;/g, "&")))];
  console.log(id, urls.slice(0, 5).join("  "));
}
