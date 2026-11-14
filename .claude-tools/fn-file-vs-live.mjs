// Compare function bodies in a migration file with live bodies (JSON from supa-query: [{proname, prosrc}]).
// Usage: node .claude-tools/fn-file-vs-live.mjs <live.json> <migration.sql>
import fs from "node:fs";
const live = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const f = fs.readFileSync(process.argv[3], "utf8").replace(/\r/g, "");
const re = /function (?:mirror|public)\.(\w+)\([\s\S]*?as \$\$([\s\S]*?)\$\$;/g;
for (const m of f.matchAll(re)) {
  const l = live.find((x) => x.proname === m[1]);
  console.log(m[1], !l ? "NOT LIVE" : l.prosrc.replace(/\r/g, "") === m[2] ? "same as file" : "DIFFERENT");
}
