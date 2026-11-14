// Writes the visible text of an HTML file to the scratch folder (read-only on the source).
import fs from "node:fs";
const [src, out] = process.argv.slice(2);
const t = fs.readFileSync(src, "utf8").replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, " ")
  .replace(/<\/(tr|p|li|h[1-6]|div|section)>/gi, "\n").replace(/<(td|th)[^>]*>/gi, " | ").replace(/<[^>]+>/g, " ")
  .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&#39;|&rsquo;/g, "'").replace(/&quot;/g, '"').replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n");
fs.writeFileSync(out, t); console.log(out, t.length);
