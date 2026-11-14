-- GENERATED into t42-daily-number-check.sql by t42-make-check.mjs (fixtures from daily-number-fixtures.mjs). Mirror T4.2 check; always rolled back.
do $chk$
declare
  r text[] := '{}'; bad text[] := '{}'; total int := 0; t date := (now() at time zone 'America/Chicago')::date; j jsonb; x uuid; a uuid; s1 uuid; n int; ok boolean;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.dn@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.dnc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1. the SQL arithmetic equals the hand-worked fixtures (the same file as the JavaScript check)
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":1000,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"utilities","amount":150,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"food","amount":400,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"transportation","amount":150,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"healthcare","amount":100,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"communication","amount":80,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"clothing","amount":120,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"household","amount":100,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"future","amount":200,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 75.62 then bad := bad || ('F1 levels.current.cost.daily: expected 75.62, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,annual}')::numeric, 2) is distinct from 27600 then bad := bad || ('F1 levels.current.cost.annual: expected 27600, got ' || coalesce(round((j #>> '{levels,current,cost,annual}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 2300 then bad := bad || ('F1 levels.current.cost.monthly: expected 2300, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,weekly}')::numeric, 2) is distinct from 529.32 then bad := bad || ('F1 levels.current.cost.weekly: expected 529.32, got ' || coalesce(round((j #>> '{levels,current,cost,weekly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"healthcare","amount":600,"frequency":"annual","paid_by":"self"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 1.64 then bad := bad || ('F2 levels.current.cost.daily: expected 1.64, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"clothing","amount":90,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 2.96 then bad := bad || ('F3 levels.current.cost.daily: expected 2.96, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":75,"frequency":"daily","paid_by":"self"}],"income":[{"amount":25,"frequency":"daily"}],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,shortfall,daily}')::numeric, 2) is distinct from 50 then bad := bad || ('F4 levels.current.shortfall.daily: expected 50, got ' || coalesce(round((j #>> '{levels,current,shortfall,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) is distinct from 1520.83 then bad := bad || ('F4 levels.current.shortfall.monthly: expected 1520.83, got ' || coalesce(round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{income,daily}')::numeric, 2) is distinct from 25 then bad := bad || ('F4 income.daily: expected 25, got ' || coalesce(round((j #>> '{income,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,resources,daily}')::numeric, 2) is distinct from 25 then bad := bad || ('F4 levels.current.resources.daily: expected 25, got ' || coalesce(round((j #>> '{levels,current,resources,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 75 then bad := bad || ('F4 levels.current.cost.daily: expected 75, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"food","amount":70,"frequency":"weekly","paid_by":"self"},{"level":"survival","category":"food","amount":140,"frequency":"biweekly","paid_by":"self"},{"level":"stability","category":"food","amount":100,"frequency":"twice_month","paid_by":"self"},{"level":"aspirational","category":"food","amount":300,"frequency":"quarterly","paid_by":"self"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 10 then bad := bad || ('F5 levels.current.cost.daily: expected 10, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,survival,cost,daily}')::numeric, 2) is distinct from 10 then bad := bad || ('F5 levels.survival.cost.daily: expected 10, got ' || coalesce(round((j #>> '{levels,survival,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,annual}')::numeric, 2) is distinct from 2400 then bad := bad || ('F5 levels.stability.cost.annual: expected 2400, got ' || coalesce(round((j #>> '{levels,stability,cost,annual}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,daily}')::numeric, 2) is distinct from 6.58 then bad := bad || ('F5 levels.stability.cost.daily: expected 6.58, got ' || coalesce(round((j #>> '{levels,stability,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,cost,annual}')::numeric, 2) is distinct from 3600 then bad := bad || ('F5 levels.aspirational.cost.annual: expected 3600, got ' || coalesce(round((j #>> '{levels,aspirational,cost,annual}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,cost,daily}')::numeric, 2) is distinct from 9.86 then bad := bad || ('F5 levels.aspirational.cost.daily: expected 9.86, got ' || coalesce(round((j #>> '{levels,aspirational,cost,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"transportation","amount":300,"frequency":"irregular","paid_by":"self","times_per_year":3},{"level":"survival","category":"household","amount":1200,"frequency":"one_time","paid_by":"self","spread_months":24},{"level":"stability","category":"household","amount":500,"frequency":"one_time","paid_by":"self","spread_months":6}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,annual}')::numeric, 2) is distinct from 900 then bad := bad || ('F6 levels.current.cost.annual: expected 900, got ' || coalesce(round((j #>> '{levels,current,cost,annual}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 2.47 then bad := bad || ('F6 levels.current.cost.daily: expected 2.47, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,survival,cost,annual}')::numeric, 2) is distinct from 600 then bad := bad || ('F6 levels.survival.cost.annual: expected 600, got ' || coalesce(round((j #>> '{levels,survival,cost,annual}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,survival,cost,daily}')::numeric, 2) is distinct from 1.64 then bad := bad || ('F6 levels.survival.cost.daily: expected 1.64, got ' || coalesce(round((j #>> '{levels,survival,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,annual}')::numeric, 2) is distinct from 1000 then bad := bad || ('F6 levels.stability.cost.annual: expected 1000, got ' || coalesce(round((j #>> '{levels,stability,cost,annual}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,monthly}')::numeric, 2) is distinct from 83.33 then bad := bad || ('F6 levels.stability.cost.monthly: expected 83.33, got ' || coalesce(round((j #>> '{levels,stability,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,daily}')::numeric, 2) is distinct from 2.74 then bad := bad || ('F6 levels.stability.cost.daily: expected 2.74, got ' || coalesce(round((j #>> '{levels,stability,cost,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":300,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"housing","amount":700,"frequency":"monthly","paid_by":"subsidy"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 32.88 then bad := bad || ('F7 levels.current.cost.daily: expected 32.88, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,paid_by_others,daily}')::numeric, 2) is distinct from 23.01 then bad := bad || ('F7 levels.current.paid_by_others.daily: expected 23.01, got ' || coalesce(round((j #>> '{levels,current,paid_by_others,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cash_expenses,daily}')::numeric, 2) is distinct from 9.86 then bad := bad || ('F7 levels.current.cash_expenses.daily: expected 9.86, got ' || coalesce(round((j #>> '{levels,current,cash_expenses,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2) is distinct from 300 then bad := bad || ('F7 levels.current.cash_needed.monthly: expected 300, got ' || coalesce(round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"food","amount":400,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"housing","amount":600,"frequency":"monthly","paid_by":"self"}],"income":[{"amount":500,"frequency":"monthly"}],"noncash":[{"category":"food","amount":250,"frequency":"monthly"}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 1000 then bad := bad || ('F8 levels.current.cost.monthly: expected 1000, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,noncash_applied,monthly}')::numeric, 2) is distinct from 250 then bad := bad || ('F8 levels.current.noncash_applied.monthly: expected 250, got ' || coalesce(round((j #>> '{levels,current,noncash_applied,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2) is distinct from 750 then bad := bad || ('F8 levels.current.cash_needed.monthly: expected 750, got ' || coalesce(round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{income,monthly}')::numeric, 2) is distinct from 500 then bad := bad || ('F8 income.monthly: expected 500, got ' || coalesce(round((j #>> '{income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{noncash,daily}')::numeric, 2) is distinct from 8.22 then bad := bad || ('F8 noncash.daily: expected 8.22, got ' || coalesce(round((j #>> '{noncash,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) is distinct from 250 then bad := bad || ('F8 levels.current.shortfall.monthly: expected 250, got ' || coalesce(round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"food","amount":400,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"housing","amount":600,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[{"category":"food","amount":500,"frequency":"monthly"}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,noncash_applied,monthly}')::numeric, 2) is distinct from 400 then bad := bad || ('F9 levels.current.noncash_applied.monthly: expected 400, got ' || coalesce(round((j #>> '{levels,current,noncash_applied,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2) is distinct from 600 then bad := bad || ('F9 levels.current.cash_needed.monthly: expected 600, got ' || coalesce(round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{noncash,monthly}')::numeric, 2) is distinct from 500 then bad := bad || ('F9 noncash.monthly: expected 500, got ' || coalesce(round((j #>> '{noncash,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":2000,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[],"tax_rate_pct":20}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2) is distinct from 2500 then bad := bad || ('F10 levels.current.gross_needed.monthly: expected 2500, got ' || coalesce(round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,gross_needed,daily}')::numeric, 2) is distinct from 82.19 then bad := bad || ('F10 levels.current.gross_needed.daily: expected 82.19, got ' || coalesce(round((j #>> '{levels,current,gross_needed,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cash_needed,daily}')::numeric, 2) is distinct from 65.75 then bad := bad || ('F10 levels.current.cash_needed.daily: expected 65.75, got ' || coalesce(round((j #>> '{levels,current,cash_needed,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"survival","category":"food","amount":600,"frequency":"monthly","paid_by":"self"},{"level":"stability","category":"housing","amount":1500,"frequency":"monthly","paid_by":"self"},{"level":"aspirational","category":"development","amount":500,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,survival,cost,daily}')::numeric, 2) is distinct from 19.73 then bad := bad || ('F11 levels.survival.cost.daily: expected 19.73, got ' || coalesce(round((j #>> '{levels,survival,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,daily}')::numeric, 2) is distinct from 49.32 then bad := bad || ('F11 levels.stability.cost.daily: expected 49.32, got ' || coalesce(round((j #>> '{levels,stability,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,cost,monthly}')::numeric, 2) is distinct from 2000 then bad := bad || ('F11 levels.aspirational.cost.monthly: expected 2000, got ' || coalesce(round((j #>> '{levels,aspirational,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,cost,daily}')::numeric, 2) is distinct from 65.75 then bad := bad || ('F11 levels.aspirational.cost.daily: expected 65.75, got ' || coalesce(round((j #>> '{levels,aspirational,cost,daily}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"household","amount":40,"frequency":"monthly","paid_by":"self","poverty_premium":true},{"level":"current","category":"housing","amount":800,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,poverty_premium,monthly}')::numeric, 2) is distinct from 40 then bad := bad || ('F12 levels.current.poverty_premium.monthly: expected 40, got ' || coalesce(round((j #>> '{levels,current,poverty_premium,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,poverty_premium,daily}')::numeric, 2) is distinct from 1.32 then bad := bad || ('F12 levels.current.poverty_premium.daily: expected 1.32, got ' || coalesce(round((j #>> '{levels,current,poverty_premium,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 840 then bad := bad || ('F12 levels.current.cost.monthly: expected 840, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","expenses":[{"level":"current","category":"housing","amount":800,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"communication","amount":50,"frequency":"monthly","paid_by":"self","end_on":"2026-10-31"},{"level":"current","category":"transportation","amount":60,"frequency":"monthly","paid_by":"self","start_on":"2026-12-01"},{"level":"current","category":"development","amount":30,"frequency":"monthly","paid_by":"self","end_on":"2026-11-13"}],"income":[{"amount":1000,"frequency":"monthly","start_on":"2027-01-05"}],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 830 then bad := bad || ('F13 levels.current.cost.monthly: expected 830, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 2 then bad := bad || ('F13 levels.current.lines: expected 2, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{income,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F13 income.monthly: expected 0, got ' || coalesce(round((j #>> '{income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) is distinct from 830 then bad := bad || ('F13 levels.current.shortfall.monthly: expected 830, got ' || coalesce(round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-12-15","expenses":[{"level":"current","category":"housing","amount":800,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"communication","amount":50,"frequency":"monthly","paid_by":"self","end_on":"2026-10-31"},{"level":"current","category":"transportation","amount":60,"frequency":"monthly","paid_by":"self","start_on":"2026-12-01"},{"level":"current","category":"development","amount":30,"frequency":"monthly","paid_by":"self","end_on":"2026-11-13"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 860 then bad := bad || ('F14 levels.current.cost.monthly: expected 860, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 2 then bad := bad || ('F14 levels.current.lines: expected 2, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","expenses":[{"level":"stability","category":"housing","amount":1000,"frequency":"monthly","paid_by":"self"}],"income":[],"noncash":[],"goals":[{"level":"stability","target_amount":1000,"current_amount":250,"target_date":"2027-05-12"},{"level":"aspirational","target_amount":2400,"current_amount":0,"target_date":"2027-11-13"},{"level":"none","target_amount":500,"current_amount":0,"target_date":"2027-03-01"},{"level":"stability","target_amount":900,"current_amount":0,"target_date":"2026-11-01"},{"level":"stability","target_amount":300,"current_amount":300,"target_date":"2027-03-01"}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,goals,monthly}')::numeric, 2) is distinct from 125 then bad := bad || ('F15 levels.stability.goals.monthly: expected 125, got ' || coalesce(round((j #>> '{levels,stability,goals,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,monthly}')::numeric, 2) is distinct from 1125 then bad := bad || ('F15 levels.stability.cost.monthly: expected 1125, got ' || coalesce(round((j #>> '{levels,stability,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,lines}')::numeric, 2) is distinct from 1 then bad := bad || ('F15 levels.stability.lines: expected 1, got ' || coalesce(round((j #>> '{levels,stability,lines}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,goals,monthly}')::numeric, 2) is distinct from 325 then bad := bad || ('F15 levels.aspirational.goals.monthly: expected 325, got ' || coalesce(round((j #>> '{levels,aspirational,goals,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,cost,monthly}')::numeric, 2) is distinct from 1325 then bad := bad || ('F15 levels.aspirational.cost.monthly: expected 1325, got ' || coalesce(round((j #>> '{levels,aspirational,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F15 levels.current.cost.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cash_needed,monthly}')::numeric, 2) is distinct from 1125 then bad := bad || ('F15 levels.stability.cash_needed.monthly: expected 1125, got ' || coalesce(round((j #>> '{levels,stability,cash_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"expenses":[{"level":"current","category":"housing","amount":600,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"food","amount":400,"frequency":"monthly","paid_by":"self"},{"level":"stability","category":"housing","amount":950,"frequency":"monthly","paid_by":"self"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self"}],"income":[{"kind":"cash_benefit","amount":943,"frequency":"monthly","applies_to":["current","survival"]},{"kind":"wages","amount":1500,"frequency":"monthly","applies_to":["stability","aspirational"]}],"noncash":[{"category":"food","amount":250,"frequency":"monthly","applies_to":["current","survival"]}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2) is distinct from 750 then bad := bad || ('F16 levels.current.cash_needed.monthly: expected 750, got ' || coalesce(round((j #>> '{levels,current,cash_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F16 levels.current.shortfall.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,resources,monthly}')::numeric, 2) is distinct from 1193 then bad := bad || ('F16 levels.current.resources.monthly: expected 1193, got ' || coalesce(round((j #>> '{levels,current,resources,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2) is distinct from 943 then bad := bad || ('F16 levels.current.untaxed_income.monthly: expected 943, got ' || coalesce(round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F16 levels.current.gross_needed.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{income,monthly}')::numeric, 2) is distinct from 943 then bad := bad || ('F16 income.monthly: expected 943, got ' || coalesce(round((j #>> '{income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,noncash_applied,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F16 levels.stability.noncash_applied.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,stability,noncash_applied,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 1500 then bad := bad || ('F16 levels.stability.income.monthly: expected 1500, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cash_needed,monthly}')::numeric, 2) is distinct from 1350 then bad := bad || ('F16 levels.stability.cash_needed.monthly: expected 1350, got ' || coalesce(round((j #>> '{levels,stability,cash_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,gross_needed,monthly}')::numeric, 2) is distinct from 1500 then bad := bad || ('F16 levels.stability.gross_needed.monthly: expected 1500, got ' || coalesce(round((j #>> '{levels,stability,gross_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,resources,monthly}')::numeric, 2) is distinct from 1500 then bad := bad || ('F16 levels.stability.resources.monthly: expected 1500, got ' || coalesce(round((j #>> '{levels,stability,resources,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,aspirational,income,monthly}')::numeric, 2) is distinct from 1500 then bad := bad || ('F16 levels.aspirational.income.monthly: expected 1500, got ' || coalesce(round((j #>> '{levels,aspirational,income,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":2000,"frequency":"monthly","paid_by":"self"}],"income":[{"kind":"cash_benefit","amount":800,"frequency":"monthly"}],"noncash":[],"tax_rate_pct":20}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2) is distinct from 1500 then bad := bad || ('F17 levels.current.gross_needed.monthly: expected 1500, got ' || coalesce(round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) is distinct from 1200 then bad := bad || ('F17 levels.current.shortfall.monthly: expected 1200, got ' || coalesce(round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2) is distinct from 800 then bad := bad || ('F17 levels.current.untaxed_income.monthly: expected 800, got ' || coalesce(round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":2000,"frequency":"monthly","paid_by":"self"}],"income":[{"kind":"cash_benefit","amount":800,"frequency":"monthly","taxable":true}],"noncash":[],"tax_rate_pct":20}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2) is distinct from 2500 then bad := bad || ('F18 levels.current.gross_needed.monthly: expected 2500, got ' || coalesce(round((j #>> '{levels,current,gross_needed,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F18 levels.current.untaxed_income.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"expenses":[{"level":"current","category":"housing","amount":800,"frequency":"monthly","paid_by":"self"},{"level":"current","category":"food","amount":300,"frequency":"monthly","paid_by":"self","active":false}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 800 then bad := bad || ('F19 levels.current.cost.monthly: expected 800, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 1 then bad := bad || ('F19 levels.current.lines: expected 1, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"noncash":[],"expenses":[{"level":"stability","category":"housing","amount":1200,"frequency":"monthly","paid_by":"self","id":"rent"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self","id":"food"}],"income":[{"id":"ssi","kind":"cash_benefit","label":"SSI","amount":943,"frequency":"monthly"},{"id":"plan-o1","kind":"wages","label":"Warehouse job","amount":270,"frequency":"weekly","times_per_year":null,"spread_months":null,"applies_to":null,"taxable":true,"planned":true}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 2116.21 then bad := bad || ('F20 levels.stability.income.monthly: expected 2116.21, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F20 levels.stability.shortfall.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,cost,monthly}')::numeric, 2) is distinct from 1600 then bad := bad || ('F20 levels.stability.cost.monthly: expected 1600, got ' || coalesce(round((j #>> '{levels,stability,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"noncash":[],"expenses":[{"level":"stability","category":"housing","amount":1200,"frequency":"monthly","paid_by":"self","id":"rent"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self","id":"food"}],"income":[{"id":"ssi","kind":"cash_benefit","label":"SSI","amount":943,"frequency":"monthly"},{"id":"plan-o2","kind":"self_employment","label":"Braiding hair","amount":200,"frequency":"monthly","times_per_year":null,"spread_months":null,"applies_to":null,"taxable":true,"planned":true}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 1143 then bad := bad || ('F21 levels.stability.income.monthly: expected 1143, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2) is distinct from 457 then bad := bad || ('F21 levels.stability.shortfall.monthly: expected 457, got ' || coalesce(round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"noncash":[],"expenses":[{"level":"stability","category":"housing","amount":1200,"frequency":"monthly","paid_by":"self","id":"rent"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self","id":"food"}],"income":[{"id":"ssi","kind":"cash_benefit","label":"SSI","amount":943,"frequency":"monthly"}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 943 then bad := bad || ('F22 levels.stability.income.monthly: expected 943, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2) is distinct from 657 then bad := bad || ('F22 levels.stability.shortfall.monthly: expected 657, got ' || coalesce(round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"noncash":[],"expenses":[{"level":"stability","category":"housing","amount":1200,"frequency":"monthly","paid_by":"self","id":"rent"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self","id":"food"}],"income":[{"id":"ssi","kind":"cash_benefit","label":"SSI","amount":943,"frequency":"monthly"},{"id":"plan-o4","kind":"wages","label":"More hours","amount":90,"frequency":"weekly","times_per_year":null,"spread_months":null,"applies_to":null,"taxable":true,"planned":true}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 1334.07 then bad := bad || ('F23 levels.stability.income.monthly: expected 1334.07, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2) is distinct from 265.93 then bad := bad || ('F23 levels.stability.shortfall.monthly: expected 265.93, got ' || coalesce(round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"noncash":[],"expenses":[{"level":"stability","category":"housing","amount":1000,"frequency":"monthly","paid_by":"self","id":"rent"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self","id":"food"}],"income":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,cost,monthly}')::numeric, 2) is distinct from 1400 then bad := bad || ('F24 levels.stability.cost.monthly: expected 1400, got ' || coalesce(round((j #>> '{levels,stability,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F24 levels.stability.income.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2) is distinct from 1400 then bad := bad || ('F24 levels.stability.shortfall.monthly: expected 1400, got ' || coalesce(round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2026-11-13","tax_rate_pct":10,"noncash":[],"expenses":[{"level":"stability","category":"housing","amount":1200,"frequency":"monthly","paid_by":"self","id":"rent"},{"level":"stability","category":"food","amount":400,"frequency":"monthly","paid_by":"self","id":"food"},{"level":"stability","category":"utilities","amount":150,"frequency":"monthly","paid_by":"self","id":"w1"}],"income":[{"id":"ssi","kind":"cash_benefit","label":"SSI","amount":943,"frequency":"monthly"},{"id":"w2","kind":"wages","label":"Job","amount":500,"frequency":"monthly"}]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,stability,cost,monthly}')::numeric, 2) is distinct from 1750 then bad := bad || ('F25 levels.stability.cost.monthly: expected 1750, got ' || coalesce(round((j #>> '{levels,stability,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,income,monthly}')::numeric, 2) is distinct from 1443 then bad := bad || ('F25 levels.stability.income.monthly: expected 1443, got ' || coalesce(round((j #>> '{levels,stability,income,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2) is distinct from 307 then bad := bad || ('F25 levels.stability.shortfall.monthly: expected 307, got ' || coalesce(round((j #>> '{levels,stability,shortfall,monthly}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2027-06-30","expenses":[{"level":"current","category":"household","amount":500,"frequency":"one_time","paid_by":"self","spread_months":6,"start_on":"2027-01-01"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 83.33 then bad := bad || ('F26 levels.current.cost.monthly: expected 83.33, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,cost,daily}')::numeric, 2) is distinct from 2.74 then bad := bad || ('F26 levels.current.cost.daily: expected 2.74, got ' || coalesce(round((j #>> '{levels,current,cost,daily}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 1 then bad := bad || ('F26 levels.current.lines: expected 1, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2027-07-01","expenses":[{"level":"current","category":"household","amount":500,"frequency":"one_time","paid_by":"self","spread_months":6,"start_on":"2027-01-01"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F27 levels.current.cost.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 0 then bad := bad || ('F27 levels.current.lines: expected 0, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2027-02-27","expenses":[{"level":"current","category":"household","amount":100,"frequency":"one_time","paid_by":"self","spread_months":1,"start_on":"2027-01-31"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 100 then bad := bad || ('F28 levels.current.cost.monthly: expected 100, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 1 then bad := bad || ('F28 levels.current.lines: expected 1, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2027-02-28","expenses":[{"level":"current","category":"household","amount":100,"frequency":"one_time","paid_by":"self","spread_months":1,"start_on":"2027-01-31"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F29 levels.current.cost.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,current,lines}')::numeric, 2) is distinct from 0 then bad := bad || ('F29 levels.current.lines: expected 0, got ' || coalesce(round((j #>> '{levels,current,lines}')::numeric, 2)::text, 'null')); end if;
  j := mirror.daily_number_calc('{"as_of":"2027-04-01","expenses":[{"level":"current","category":"household","amount":600,"frequency":"one_time","paid_by":"self","spread_months":6,"start_on":"2027-01-01","end_on":"2027-03-31"},{"level":"survival","category":"household","amount":600,"frequency":"one_time","paid_by":"self","spread_months":6,"start_on":"2027-01-01","end_on":"2027-04-01"}],"income":[],"noncash":[]}'::jsonb);
  total := total + 1; if round((j #>> '{levels,current,cost,monthly}')::numeric, 2) is distinct from 0 then bad := bad || ('F30 levels.current.cost.monthly: expected 0, got ' || coalesce(round((j #>> '{levels,current,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  total := total + 1; if round((j #>> '{levels,survival,cost,monthly}')::numeric, 2) is distinct from 100 then bad := bad || ('F30 levels.survival.cost.monthly: expected 100, got ' || coalesce(round((j #>> '{levels,survival,cost,monthly}')::numeric, 2)::text, 'null')); end if;
  r := r || format('1 SQL calculation vs hand-worked fixtures: %s of %s figures match%s', total - cardinality(bad), total,
    case when cardinality(bad) > 0 then ' FAILS: ' || array_to_string(bad, '; ') else '' end);
  r := r || format('2 categories seeded: %s (12)', (select count(*) from mirror.expense_categories));

  -- 3. a person builds a Daily Number through the page functions; the result equals the fixture
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.dn@example.invalid', 'CHECK DN') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.dnc@example.invalid', 'CHECK DNC', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"Groceries","amount":"$400","frequency":"monthly"}');
  perform public.mirror_dn_save('expense', '{"level":"current","category":"housing","label":"Rent","amount":"600","frequency":"monthly"}');
  perform public.mirror_dn_save('income', '{"kind":"wages","label":"Job","amount":"500","frequency":"monthly"}');
  j := public.mirror_dn_save('noncash', '{"kind":"snap","category":"food","label":"SNAP","amount":"250","frequency":"monthly"}');
  ok := round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) = 250 and round((j #>> '{levels,current,noncash_applied,monthly}')::numeric, 2) = 250
    and round((j #>> '{income,monthly}')::numeric, 2) = 500;
  perform public.mirror_dn_save('settings', '{"tax_rate_pct":"20"}');
  j := public.mirror_dn_get();
  ok := ok and round((j #>> '{results,levels,current,gross_needed,monthly}')::numeric, 2) = 937.50 and jsonb_array_length(j #> '{inputs,expenses}') = 2;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"-5","frequency":"monthly"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"nope","label":"x","amount":"5","frequency":"monthly"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"irregular"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"category":"food","label":"x","amount":"5","frequency":"monthly"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('3 person enters costs, wages, SNAP, 20%% tax: shortfall $250/month, before-tax $937.50/month; bad entries refused: %s', ok);

  -- 4. snapshots keep inputs and results and cannot be changed
  s1 := public.mirror_dn_snapshot('Staying with my sister');
  perform public.mirror_dn_save('expense', '{"level":"current","category":"housing","label":"Rent","amount":"900","frequency":"monthly"}');
  j := public.mirror_dn_history();
  ok := jsonb_array_length(j) = 1 and round((j -> 0 #>> '{results,levels,current,cost,monthly}')::numeric, 2) = 1000;
  execute 'reset role';
  begin update mirror.daily_number_snapshots set note = 'x' where id = s1; ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('role', 'authenticated', true);
  r := r || format('4 snapshot keeps the old numbers after a change, and cannot be edited: %s', ok);

  -- 5. coordinator: refused until the person shares money; then view only; the look is logged
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_dn_get(a); ok := false; exception when insufficient_privilege then ok := true; end;
  execute 'reset role';
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (a, x, 'financial', 'view', 'check.dn@example.invalid');
  perform set_config('role', 'authenticated', true);
  j := public.mirror_dn_get(a);
  ok := ok and not (j ->> 'can_edit')::boolean and jsonb_array_length(j #> '{inputs,expenses}') = 3;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"monthly"}', a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and category = 'financial' and action = 'view';
  r := r || format('5 coordinator: no money access until shared; then view only; looks logged (%s): %s', n, ok and n >= 1);

  -- 7. the fixes of 11/13: dates, goals, copy all-or-nothing, the download includes the Daily Number
  execute 'reset role';
  delete from mirror.consents where individual_id = a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('expense', jsonb_build_object('level', 'current', 'category', 'communication', 'label', 'Old phone', 'amount', '50', 'frequency', 'monthly',
    'end_on', (t - 1)::text));
  perform public.mirror_dn_save('expense', jsonb_build_object('level', 'current', 'category', 'transportation', 'label', 'Bus pass', 'amount', '60', 'frequency', 'monthly',
    'start_on', (t + 20)::text));
  j := public.mirror_dn_get();
  ok := round((j #>> '{results,levels,current,cost,monthly}')::numeric, 2) = 1900 and jsonb_array_length(j #> '{inputs,expenses}') = 5;   -- 400 + 600 + 900 counted; old phone and future bus pass listed only
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"monthly","start_on":"2027-02-01","end_on":"2027-01-01"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"monthly","start_on":"2027-02-31"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('7a [counted %s/month, listed %s lines] ended and not-yet-started costs listed but not counted; bad dates refused: %s', round((j #>> '{results,levels,current,cost,monthly}')::numeric, 2), jsonb_array_length(j #> '{inputs,expenses}'), ok);

  j := public.mirror_dn_save('goal', jsonb_build_object('kind', 'emergency_reserve', 'label', 'Emergency fund', 'level', 'stability', 'target_amount', '1200',
    'current_amount', '0', 'target_date', (t + 365)::text));
  ok := round((j #>> '{levels,stability,goals,monthly}')::numeric, 2) = 100 and round((j #>> '{levels,aspirational,goals,monthly}')::numeric, 2) = 100;
  perform public.mirror_dn_save('goal', jsonb_build_object('kind', 'savings', 'label', 'Not counted', 'level', 'none', 'target_amount', '500', 'target_date', (t + 100)::text));
  j := public.mirror_dn_get();
  ok := ok and round((j #>> '{results,levels,stability,goals,monthly}')::numeric, 2) = 100 and jsonb_array_length(j -> 'goals') = 2;
  r := r || format('7b goal $1,200 in 12 months counts $100/month in Stability and The life I want; a goal set "not counted" adds nothing: %s', ok);

  j := public.mirror_dn_copy('current', 'survival');
  total := (j ->> 'copied')::int; ok := total = 5;
  begin perform public.mirror_dn_copy('current', 'current'); ok := ok and false; exception when invalid_parameter_value then null; end;
  execute 'reset role';
  select count(*) into n from mirror.living_expenses where individual_id = a and level = 'survival';
  -- all or nothing: a failing copy (a row that breaks a rule) leaves no partial copy behind
  begin
    perform set_config('role', 'authenticated', true);
    perform public.mirror_dn_copy('current', 'stability');
    execute 'reset role';
    update mirror.living_expenses set amount = -1 where individual_id = a and level = 'stability';
    ok := false;
  exception when check_violation then execute 'reset role'; end;
  select count(*) + n into n from mirror.living_expenses where individual_id = a and level = 'stability';
  r := r || format('7c [copied %s; survival + stability rows after a failed copy step = %s] copy is one step, a failed step leaves nothing: %s', total, n, ok and n = 5);
  perform set_config('role', 'authenticated', true);

  j := public.mirror_my_export();
  total := jsonb_array_length(j #> '{daily_number,inputs,expenses}');
  ok := total = 10 and jsonb_array_length(j #> '{daily_number,inputs,goals}') = 2
    and jsonb_array_length(j #> '{daily_number,saved}') = 1 and (j #>> '{daily_number,results,method}')::int >= 2;
  r := r || format('7d [%s cost lines] the download includes the Daily Number (2 goals, 1 saved number, method 2 or later): %s', total, ok);
  execute 'reset role';

  -- 8. step 2 (trustworthy): resources per level, untaxed income, automatic save before the first change of a new day
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_dn_save('income', '{"kind":"cash_benefit","label":"SSI","amount":"943","frequency":"monthly","applies_to":["current","survival"]}');
  ok := round((j #>> '{levels,current,income,monthly}')::numeric, 2) = 1443 and round((j #>> '{levels,stability,income,monthly}')::numeric, 2) = 500
    and round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2) = 943 and (j ->> 'method')::int = 4;
  j := public.mirror_dn_get();
  ok := ok and (select count(*) from jsonb_array_elements(j #> '{inputs,income}') ii where ii ->> 'label' = 'SSI' and ii -> 'applies_to' = '["current", "survival"]'::jsonb) = 1;
  perform public.mirror_dn_save('income', '{"kind":"wages","label":"Side job","amount":"100","frequency":"monthly","applies_to":["current","survival","stability","aspirational"],"taxable":"false"}');
  execute 'reset role';
  select count(*) into n from mirror.income_sources where individual_id = a and label = 'Side job' and applies_to is null and taxable = false;
  r := r || format('8a SSI counted only today and in Survival (today $1,443/month income, Stability $500), untaxed; all four levels saved as "all"; taxed flag kept: %s', ok and n = 1);

  -- pretend everything (lines and saved numbers) is from two days ago, then make two changes today:
  -- the numbers as they were are saved first, once; the second change saves nothing more
  alter table mirror.living_expenses disable trigger living_expenses_touch;
  alter table mirror.income_sources disable trigger income_sources_touch;
  alter table mirror.noncash_resources disable trigger noncash_resources_touch;
  alter table mirror.financial_goals disable trigger financial_goals_touch;
  alter table mirror.daily_number_snapshots disable trigger daily_number_snapshots_never_change;
  update mirror.living_expenses set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.income_sources set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.noncash_resources set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.financial_goals set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.daily_number_settings set updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.daily_number_snapshots set taken_at = now() - interval '3 days' where individual_id = a;
  alter table mirror.living_expenses enable trigger living_expenses_touch;
  alter table mirror.income_sources enable trigger income_sources_touch;
  alter table mirror.noncash_resources enable trigger noncash_resources_touch;
  alter table mirror.financial_goals enable trigger financial_goals_touch;
  alter table mirror.daily_number_snapshots enable trigger daily_number_snapshots_never_change;
  select count(*) into n from mirror.daily_number_snapshots where individual_id = a;
  perform set_config('role', 'authenticated', true);
  perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"Coffee","amount":"20","frequency":"monthly"}');
  perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"Tea","amount":"10","frequency":"monthly"}');
  execute 'reset role';
  select count(*) - n into n from mirror.daily_number_snapshots where individual_id = a;
  ok := n = 1 and exists (select 1 from mirror.daily_number_snapshots where individual_id = a and note like 'Saved automatically%'
       and not (inputs -> 'expenses') @> '[{"label":"Coffee"}]' and method_version = (results ->> 'method')::int and method_version = 4);
  r := r || format('8b first change on a new day saves the numbers as they were (without Coffee), once, method 4 recorded as calculated (new rows %s, expected 1): %s', n, ok);
  perform set_config('role', 'authenticated', true);
  s1 := public.mirror_dn_snapshot('manual');
  execute 'reset role';
  r := r || format('8c a manual save now records method %s (was always 1)', (select method_version from mirror.daily_number_snapshots where id = s1));

  -- 6. deleting the person removes their Daily Number and snapshots
  delete from mirror.individuals where id = a;
  select (select count(*) from mirror.living_expenses where individual_id = a) + (select count(*) from mirror.daily_number_snapshots where individual_id = a) into n;
  r := r || format('6 person deleted: Daily Number rows left %s (0)', n);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
