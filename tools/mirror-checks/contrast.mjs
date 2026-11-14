// The Human Mirror: colour contrast check (T1.1, read-only, D-01).
//   node tools/mirror-checks/contrast.mjs            -> prints every pair, exits 1 if any fails
// Reads the light tokens (first :root block) and the dark tokens (:root[data-theme="dark"]) from site/mirror/assets/mirror.css
// and checks WCAG 2.1 contrast: 4.5:1 for text pairs, 3:1 for controls, focus rings and bars.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "..", "..", "site", "mirror", "assets", "mirror.css"), "utf8");

/** @param {string} block */
function tokens(block) {
  /** @type {Record<string,string>} */ const t = {};
  for (const m of block.matchAll(/--mm-([a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})/g)) t[m[1]] = m[2];
  return t;
}
const lightBlock = css.slice(css.indexOf(":root {"), css.indexOf("}", css.indexOf(":root {")));
const darkStart = css.indexOf(':root[data-theme="dark"] {');
const darkBlock = css.slice(darkStart, css.indexOf("}", darkStart));
const light = tokens(lightBlock);
const dark = { ...light, ...tokens(darkBlock) };
// The system dark mode block and the chosen dark theme block must carry the same colours.
const sysStart = css.indexOf(':root:not([data-theme="light"]) {');
const sysDark = tokens(css.slice(sysStart, css.indexOf("}", sysStart)));
const darkOwn = tokens(darkBlock);
const drift = Object.keys({ ...sysDark, ...darkOwn }).filter((k) => sysDark[k] !== darkOwn[k]);
if (drift.length) { console.log(`FAIL dark blocks differ: ${drift.join(", ")}`); process.exitCode = 1; }

/** @param {string} hex */
function lum(hex) {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
/** @param {string} a @param {string} b */
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

const TEXT = [
  ["ink", "bg"], ["ink", "surface"], ["ink", "surface-2"], ["ink-2", "bg"], ["ink-2", "surface"], ["ink-2", "surface-2"],
  ["accent", "bg"], ["accent", "surface"], ["accent-ink", "accent"], ["accent-ink", "accent-hover"], ["accent-hover", "bg"],
  ["warm", "bg"], ["warm", "surface"], ["ink", "accent-soft"], ["ink-2", "accent-soft"], ["ink", "warm-soft"], ["ink-2", "warm-soft"],
  ["urgent", "urgent-soft"], ["urgent", "bg"], ["urgent", "surface"], ["ok", "ok-soft"], ["caution", "caution-soft"], ["info", "info-soft"],
  ["ink", "urgent-soft"], ["ink", "ok-soft"], ["ink", "caution-soft"], ["ink", "info-soft"], ["bg", "ink"],
];
const NONTEXT = [["control", "bg"], ["control", "surface"], ["focus", "bg"], ["focus", "surface"], ["accent", "surface-2"], ["urgent", "surface"]];

let fails = 0;
for (const [name, t] of [["light", light], ["dark", dark]]) {
  console.log(`\n${name} theme`);
  for (const [list, min] of [[TEXT, 4.5], [NONTEXT, 3]]) {
    for (const [fg, bg] of list) {
      if (!t[fg] || !t[bg]) { console.log(`  MISSING ${fg} or ${bg}`); fails++; continue; }
      const r = ratio(t[fg], t[bg]);
      const ok = r >= min;
      if (!ok) fails++;
      console.log(`  ${ok ? "ok  " : "FAIL"} ${fg} on ${bg}: ${r.toFixed(2)} (needs ${min})`);
    }
  }
}
console.log(fails ? `\n${fails} pair(s) fail` : "\nAll pairs pass");
process.exit(fails || process.exitCode ? 1 : 0);
