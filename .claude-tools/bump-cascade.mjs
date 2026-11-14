// Gives changed Mirror assets a new ?v= everywhere they are imported, then does the same for every asset that imports them
// (its text changed too), until nothing new changes. Cloudflare caches assets 4 hours (K-05), so every importer must move.
// Usage: node .claude-tools/bump-cascade.mjs <newVersion> <asset.js> [more assets...]
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, basename } from "node:path";

const [ver, ...start] = process.argv.slice(2);
if (!ver || !start.length) { console.error("usage: <newVersion> <asset.js>..."); process.exit(2); }
/** @param {string} d @returns {string[]} */
const walk = (d) => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : [p]; });
const files = walk("site/mirror").filter((f) => /\.(html|js)$/.test(f));
const queue = [...start.map((s) => basename(s))], done = new Set();
const changed = new Set();
while (queue.length) {
  const a = /** @type {string} */ (queue.shift());
  if (done.has(a)) continue;
  done.add(a);
  const re = new RegExp("(/mirror/assets/" + a.replace(/[.]/g, "\\.") + "\\?v=)[0-9a-z]+", "g");
  for (const f of files) {
    const t = readFileSync(f, "utf8");
    const u = t.replace(re, "$1" + ver);
    if (u !== t) {
      writeFileSync(f, u);
      changed.add(f);
      if (f.includes(join("site", "mirror", "assets")) && f.endsWith(".js")) queue.push(basename(f));
    }
  }
}
console.log("assets given ?v=" + ver + ": " + [...done].join(", "));
console.log("files changed: " + changed.size);
