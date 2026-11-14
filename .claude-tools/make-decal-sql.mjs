// Usage: node .claude-tools/make-decal-sql.mjs <unit> <photo.jpg> <where-text-file> <out.sql> [send-now: yes|no]
// Writes a LOCAL-ONLY migration that sets a unit's parking decal pick-up spot (text + photo) and, with "yes",
// emails the unit's people now for a vehicle already registered, then flushes the outbox.
import { readFileSync, writeFileSync } from "node:fs";
const [unit, photo, textFile, out, sendNow] = process.argv.slice(2);
if (!unit || !photo || !textFile || !out) { console.error("args: unit photo textfile out [yes]"); process.exit(1); }
const b64 = readFileSync(photo).toString("base64");
const where = readFileSync(textFile, "utf8").trim();
if (where.includes("$w$")) throw new Error("bad text");
const u = unit.replace(/[^0-9A-Za-z]/g, "");
let sql = `-- LOCAL ONLY (gitignored): parking decal pick-up spot for Unit ${u}. Never commit.
insert into parking_decal_pickups (unit_number, where_text, photo_b64, photo_name, active, updated_at, updated_by)
values ('${u}', $w$${where}$w$, '${b64}', 'unit-${u}-decal-pickup.jpg', true, now(), 'claude for stephen')
on conflict (unit_number) do update set where_text = excluded.where_text, photo_b64 = excluded.photo_b64, photo_name = excluded.photo_name,
  active = true, updated_at = now(), updated_by = excluded.updated_by;
`;
if (sendNow === "yes") sql += `
do $do$
declare v_secret text; n int;
begin
  n := parking_decal_pickup_notify('${u}', (select id from vehicles where unit_number = '${u}' and status = 'active' order by (kind = 'own') desc, created_at limit 1));
  raise notice 'Unit ${u}: % decal pick-up email(s) queued', n;
  if n > 0 then
    select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
    if v_secret is not null then
      perform net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', v_secret), body := '{}'::jsonb);
    end if;
  end if;
end;
$do$;
`;
writeFileSync(out, sql);
console.log(`wrote ${out} (${Math.round(b64.length / 1024)} KB photo)`);
