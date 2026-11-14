// Corrects the P3-06b version note: since f8fe27e every engine user imports ?v=20261113p, which carries P3-06b.
import fs from "node:fs";
const f = "docs/human-mirror/KNOWN_ISSUES.md";
let s = fs.readFileSync(f, "utf8");
const a = "daily-number-page.js, functional-page.js and workspace/person still import the engine at ?v=20261113j (same file; they get it once the 4-hour browser cache expires, or at their owners' next bump).";
if (!s.includes(a)) throw new Error("note not found");
s = s.replace(a, "Since commit f8fe27e (another session, 09:40) every engine user imports ?v=20261113p, which carries P3-06b (checked live).");
fs.writeFileSync(f, s);
console.log("updated");
