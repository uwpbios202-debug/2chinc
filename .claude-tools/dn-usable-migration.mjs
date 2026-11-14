// Builds supabase/migrations/20261119262000_mirror_daily_number_usable.sql from the step-2 functions plus premium_kind.
import fs from "node:fs";
const src = fs.readFileSync("supabase/migrations/20261119250000_mirror_daily_number_trust.sql", "utf8");
const grab = (start) => { const a = src.indexOf(start); if (a < 0) throw new Error("missing " + start); const end = src.indexOf("$$;", src.indexOf("as $$", a) + 5); return src.slice(a, end + 3); };
let inputs = grab("create or replace function mirror.daily_number_inputs(");
let save = grab("create or replace function public.mirror_dn_save(");
const sub = (s, a, b) => { if (!s.includes(a)) throw new Error("miss " + a.slice(0, 70)); return s.split(a).join(b); };

inputs = sub(inputs, "'poverty_premium', e.poverty_premium, 'note', e.note,", "'poverty_premium', e.poverty_premium, 'premium_kind', e.premium_kind, 'note', e.note,");
save = sub(save, "  v_taxable boolean := case when p ->> 'taxable' in ('true', 'false') then (p ->> 'taxable')::boolean end;\n",
  "  v_taxable boolean := case when p ->> 'taxable' in ('true', 'false') then (p ->> 'taxable')::boolean end;\n  v_premium_kind text := nullif(p ->> 'premium_kind', '');\n  v_premium boolean := coalesce((p ->> 'poverty_premium')::boolean, false) or v_premium_kind is not null;\n");
save = sub(save, "insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note, start_on, end_on)\n      values (v, p ->> 'level', p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, coalesce(nullif(p ->> 'paid_by', ''), 'self'),\n              coalesce((p ->> 'poverty_premium')::boolean, false), nullif(btrim(p ->> 'note'), ''), v_start, v_end);",
  "insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, premium_kind, note, start_on, end_on)\n      values (v, p ->> 'level', p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, coalesce(nullif(p ->> 'paid_by', ''), 'self'),\n              v_premium, v_premium_kind, nullif(btrim(p ->> 'note'), ''), v_start, v_end);");
save = sub(save, "        poverty_premium = coalesce((p ->> 'poverty_premium')::boolean, false), note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end\n      where id = v_id and individual_id = v;",
  "        poverty_premium = v_premium, premium_kind = v_premium_kind, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end\n      where id = v_id and individual_id = v;");

const KINDS = ["small_quantities", "convenience_store", "laundromat", "prepaid_phone", "long_commute", "per_ride_fares", "late_fees", "overdraft",
  "check_cashing", "payday_loan", "rent_to_own", "no_reserve", "other"];
const out = `-- The Human Mirror, Daily Number step 3 "make it usable" (Stephen, 11/13/2026).
-- premium_kind: which "cost of being poor" a line is (the paper's section 7), so the gap page can show a cheaper way for each.
-- Choosing a kind also marks the line as a cost that could go down. mirror_dn_save and mirror.daily_number_inputs are the step-2
-- versions (migration 20261119250000) with premium_kind added; nothing else in them changed.

alter table mirror.living_expenses add column premium_kind text check (premium_kind is null or premium_kind in (${KINDS.map((k) => "'" + k + "'").join(", ")}));

${inputs}

${save}
`;
fs.writeFileSync("supabase/migrations/20261119262000_mirror_daily_number_usable.sql", out);
console.log("written");
