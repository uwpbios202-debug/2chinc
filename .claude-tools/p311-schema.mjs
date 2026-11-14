// Moves dblink into a private schema (mirror_link) in the P3-11 migration and fixes the header line about it.
import fs from "node:fs";
const f = "supabase/migrations/20261119284000_mirror_refusals_kept.sql";
let s = fs.readFileSync(f, "utf8");
const start = s.indexOf("create extension if not exists dblink with schema extensions;");
const end = s.indexOf("end $$;", start) + "end $$;".length;
if (start < 0 || end < start) throw new Error("block not found");
s = s.slice(0, start) +
`-- dblink lives in its own schema that only the owner (postgres) can use. Its functions belong to the Supabase superuser and stay
-- executable by PUBLIC, but nobody can call a function in a schema they have no USAGE on, so anon and authenticated cannot reach it.
create schema if not exists mirror_link;
revoke all on schema mirror_link from public, anon, authenticated, service_role;
create extension if not exists dblink with schema mirror_link;` + s.slice(end);
s = s.replace("--  * dblink functions: execute taken away from anon and authenticated (the extensions schema is not on the Data API either).",
  "--  * dblink is installed in a private schema, mirror_link, that only postgres can use (anon, authenticated and service_role cannot).");
const n = (s.match(/extensions\.dblink\(/g) || []).length;
s = s.split("extensions.dblink(").join("mirror_link.dblink(");
s = s.split("set search_path = mirror, public, extensions as").join("set search_path = mirror, public, extensions, mirror_link as");
fs.writeFileSync(f, s);
console.log("dblink calls moved:", n);
