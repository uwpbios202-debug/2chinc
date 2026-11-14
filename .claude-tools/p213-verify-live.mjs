// P2-13: before applying, confirm the 12 live function bodies still equal the copies the migration was built from. (one-off; not committed)
import fs from "node:fs";
import { execFileSync } from "node:child_process";
const dir = process.argv[2];
const names = fs.readdirSync(dir).filter((f) => f.endsWith(".sql") && /^(public|mirror)\./.test(f)).map((f) => f.slice(0, -4));
const list = names.map((n) => `'${n}'`).join(",");
const out = execFileSync("sh", ["./.claude-tools/supa-query.sh",
  `select n.nspname||'.'||p.proname as name, pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname||'.'||p.proname in (${list})`], { encoding: "utf8" });
const live = Object.fromEntries(JSON.parse(out).map((r) => [r.name, r.d]));
let bad = 0;
for (const n of names) {
  const same = live[n] && live[n].trim() === fs.readFileSync(`${dir}/${n}.sql`, "utf8").trim();
  if (!same) bad++;
  console.log((same ? "same     " : "CHANGED  ") + n);
}
console.log(bad ? `${bad} changed: do not apply` : `all ${names.length} unchanged`);
