// Lists the catalog entries (id, name, one-line summary) of each given audit file. Read-only.
import fs from "node:fs";
for (const f of process.argv.slice(2)) {
  const t = fs.readFileSync(f, "utf8").replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, " ").replace(/<\/(tr|p|li|h[1-6]|div|section)>/gi, "\n")
    .replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&#x27;|&#39;|&rsquo;/g, "'").replace(/&quot;/g, '"').replace(/[ \t]+/g, " ");
  const seen = new Set();
  console.log("== " + f.split("/").pop().replace("_Folder_Audit.html", ""));
  for (const m of t.matchAll(/\n\s*([A-Z]{2,6}-[A-Z0-9]{1,4}-\d{2,3}) · ([^\n]{0,230})/g)) { if (seen.has(m[1])) continue; seen.add(m[1]); console.log(m[1] + " · " + m[2].trim()); }
}
