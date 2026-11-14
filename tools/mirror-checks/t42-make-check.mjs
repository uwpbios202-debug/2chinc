// Writes tools/mirror-checks/t42-daily-number-check.sql: the SQL calculation must give the same cents as daily-number.js for every
// hand-worked fixture, plus access and history checks. Run: node tools/mirror-checks/t42-make-check.mjs
import fs from "node:fs";
import { FIXTURES } from "./daily-number-fixtures.mjs";

const lit = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const sqlPath = (p) => "{" + p.split(".").join(",") + "}";
const lines = [];
FIXTURES.forEach(([, input, expect], i) => {
  lines.push(`  j := mirror.daily_number_calc(${lit(JSON.stringify(input))}::jsonb);`);
  for (const [p, v] of expect) {
    const at = `round((j #>> ${lit(sqlPath(p))})::numeric, 2)`;
    lines.push(`  total := total + 1; if ${at} is distinct from ${v} then bad := bad || (${lit(`F${i + 1} ${p}: expected ${v}, got `)} || coalesce(${at}::text, 'null')); end if;`);
  }
});

const body = fs.readFileSync(new URL("./t42-check-body.sql", import.meta.url), "utf8");
fs.writeFileSync(new URL("./t42-daily-number-check.sql", import.meta.url), body.replace("--FIXTURES--", lines.join("\n")));
console.log("written: " + lines.length + " lines of fixtures");
