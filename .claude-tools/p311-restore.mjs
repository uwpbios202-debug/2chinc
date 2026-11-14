// Rebuilds 20261119284000 exactly as applied: header + tolerant revoke loop + live gate with the 3 swaps.
import fs from "node:fs";
const [head, live, out] = process.argv.slice(2);
let h = fs.readFileSync(head, "utf8");
const a = "    execute format('revoke all on function %s from anon, authenticated', f.sig);\n  end loop;";
if (!h.includes(a)) throw new Error("revoke line not found");
h = h.replace(a, "    begin\n      execute format('revoke all on function %s from public, anon, authenticated', f.sig);\n    exception when insufficient_privilege then null;   -- dblink_connect_u and the like: owned by the superuser, already closed\n    end;\n  end loop;");
let b = fs.readFileSync(live, "utf8"); let n = 0;
b = b.replace(/perform mirror\.audit\(([^;]*?), 'refused', ([^;]*?)\);/g, (_m, x, c) => { n++; return `perform mirror.audit_refused(${x}, ${c});`; });
if (n !== 3) throw new Error("expected 3, got " + n);
b = b.split("$function$").join("$gate$") + ";\n";
fs.writeFileSync(out, h + b);
console.log("rebuilt");
