// Compare ONE function's body in a migration file with the live body. Usage: node .claude-tools/fn-one-vs-live.mjs <live.json> <migration.sql> <schema.name>
import fs from "node:fs";
const [, , liveFile, migFile, qname] = process.argv;
const name = qname.split(".").pop();
const live = JSON.parse(fs.readFileSync(liveFile, "utf8")).find((x) => x.proname === name);
const f = fs.readFileSync(migFile, "utf8").replace(/\r/g, "");
const start = f.toLowerCase().indexOf("create or replace function " + qname.toLowerCase() + "(");
const tag = f.slice(start).match(/\$[a-z_]*\$/i)[0];
const open = f.indexOf(tag, start), close = f.indexOf(tag, open + tag.length);
const body = f.slice(open + tag.length, close);
console.log(qname, !live ? "NOT LIVE" : live.prosrc.replace(/\r/g, "") === body ? "same as file" : "DIFFERENT");
