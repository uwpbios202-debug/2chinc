// Prints each audit's numbered sources "R<n> · title" followed by the first link after it. Read-only.
import fs from "node:fs";
const dir = "Issues and fixes/Databases_TheMirror/";
for (const f of process.argv.slice(2)) {
  const t = fs.readFileSync(dir + "Milwaukee_" + f + "_Folder_Audit.html", "utf8").replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, " ")
    .replace(/<a [^>]*href="([^"]+)"[^>]*>/g, " $1 ").replace(/<\/(tr|p|li|h[1-6]|div|section)>/gi, "\n").replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&#x27;|&#39;|&rsquo;/g, "'").replace(/[ \t]+/g, " ");
  console.log("== " + f);
  const seen = new Set();
  for (const m of t.matchAll(/\n\s*(R\d+) · ([^\n]{3,140})\n([\s\S]{0,600}?)(https?:\/\/[^\s|"<)]+)/g)) {
    if (seen.has(m[1])) continue; seen.add(m[1]); console.log(m[1] + " · " + m[2].trim() + "  ->  " + m[4]);
  }
}
