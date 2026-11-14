// Living Options no-JavaScript list check (Stephen, 11/13/2026): the seven lines inside <div id="mmOptions"> on
// site/mirror/living-options/index.html must match OPTIONS (title + summary, same order) in site/mirror/assets/living-options.js.
// Run: node tools/mirror-checks/living-options-fallback.mjs     (prints PASS, or each line that differs, and exits 1)
import fs from "node:fs";
import { OPTIONS } from "../../site/mirror/assets/living-options.js";

const html = fs.readFileSync(new URL("../../site/mirror/living-options/index.html", import.meta.url), "utf8");
const box = html.match(/<div id="mmOptions">([\s\S]*?)<\/ul>/);
const lines = box ? [...box[1].matchAll(/<li><strong>(.*?)\.<\/strong> (.*?)<\/li>/g)].map((m) => [m[1], m[2]]) : [];
const bad = [];
if (lines.length !== OPTIONS.length) bad.push(`the page lists ${lines.length} options, OPTIONS has ${OPTIONS.length}`);
OPTIONS.forEach((o, i) => {
  const [t, s] = lines[i] || ["(missing)", "(missing)"];
  if (t !== o.title) bad.push(`option ${i + 1} title: page "${t}", OPTIONS "${o.title}"`);
  if (s !== o.summary) bad.push(`option ${i + 1} summary: page "${s}", OPTIONS "${o.summary}"`);
});
if (bad.length) { console.log("FAIL"); bad.forEach((b) => console.log("  " + b)); process.exit(1); }
console.log(`PASS  ${OPTIONS.length}/${OPTIONS.length} no-JavaScript lines match OPTIONS`);
