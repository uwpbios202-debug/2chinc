-- The Human Mirror, Phase 4: one-time costs (Stephen, 11/13/2026, known issue K-09, option A). Method version 4, same arithmetic as daily-number.js.
-- A one-time cost spread over m months now counts amount / m each month (a year's rate = amount x 12 / m), and only during those m months:
-- from its start date through start + m months - 1 day (or its own end date if that is earlier). Before, it was spread over at least 12
-- months and never stopped. Example: $500 over 6 months = $83.33 a month ($2.74 a day) for those 6 months, then $0.
-- No saved line or snapshot is changed; snapshots keep the method version they were calculated with.

create or replace function mirror.dn_end_on(x jsonb) returns date
language sql immutable set search_path = mirror, public as $$
  select case
    when x ->> 'frequency' = 'one_time' and nullif(x ->> 'start_on', '') is not null then
      least(nullif(x ->> 'end_on', '')::date,
            ((x ->> 'start_on')::date + make_interval(months => greatest(coalesce(nullif(nullif(x ->> 'spread_months', '')::int, 0), 12), 1)))::date - 1)
    else nullif(x ->> 'end_on', '')::date end;
$$;

CREATE OR REPLACE FUNCTION mirror.annual_of(p_amount numeric, p_frequency text, p_times numeric, p_spread integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_frequency
    when 'daily' then p_amount * 365
    when 'weekly' then p_amount * 365 / 7
    when 'biweekly' then p_amount * 365 / 14
    when 'twice_month' then p_amount * 24
    when 'monthly' then p_amount * 12
    when 'quarterly' then p_amount * 4
    when 'annual' then p_amount
    when 'irregular' then p_amount * coalesce(p_times, 0)
    when 'one_time' then p_amount * 12 / greatest(coalesce(nullif(p_spread, 0), 12), 1)
    else 0 end;
$function$;

CREATE OR REPLACE FUNCTION mirror.dn_lines(p jsonb, p_as_of date)
 RETURNS TABLE(kind text, level text, cat text, paid_by text, premium boolean, goal boolean, y numeric, applies text[], taxable boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'mirror', 'public'
AS $function$
  select 'expense', x ->> 'level', x ->> 'category', x ->> 'paid_by', coalesce((x ->> 'poverty_premium')::boolean, false), false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int), null::text[], null::boolean
  from jsonb_array_elements(coalesce(p -> 'expenses', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (mirror.dn_end_on(x) is null or mirror.dn_end_on(x) >= p_as_of)
  union all
  select 'goal', coalesce(g ->> 'level', 'stability'), 'future', 'self', false, true,
         12 * mirror.goal_monthly((g ->> 'target_amount')::numeric, (g ->> 'current_amount')::numeric, nullif(g ->> 'target_date', '')::date, p_as_of), null, null
  from jsonb_array_elements(coalesce(p -> 'goals', '[]')) g
  where coalesce(g ->> 'level', 'stability') <> 'none'
    and mirror.goal_monthly((g ->> 'target_amount')::numeric, (g ->> 'current_amount')::numeric, nullif(g ->> 'target_date', '')::date, p_as_of) > 0
  union all
  select 'income', null, null, null, false, false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int),
         case when jsonb_typeof(x -> 'applies_to') = 'array' then array(select jsonb_array_elements_text(x -> 'applies_to')) end,
         coalesce((x ->> 'taxable')::boolean, x ->> 'kind' is null or x ->> 'kind' in ('wages', 'self_employment', 'pension'))
  from jsonb_array_elements(coalesce(p -> 'income', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (mirror.dn_end_on(x) is null or mirror.dn_end_on(x) >= p_as_of)
  union all
  select 'noncash', null, x ->> 'category', null, false, false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int),
         case when jsonb_typeof(x -> 'applies_to') = 'array' then array(select jsonb_array_elements_text(x -> 'applies_to')) end, null
  from jsonb_array_elements(coalesce(p -> 'noncash', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (mirror.dn_end_on(x) is null or mirror.dn_end_on(x) >= p_as_of);
$function$;

CREATE OR REPLACE FUNCTION mirror.daily_number_calc(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_as_of date := coalesce(nullif(p ->> 'as_of', '')::date, (now() at time zone 'America/Chicago')::date);
  v_tax numeric := least(greatest(coalesce((p ->> 'tax_rate_pct')::numeric, 0), 0), 90) / 100;
  v_levels jsonb := '{}'::jsonb;
  lv text;
  v_cost numeric; v_cash numeric; v_others numeric; v_premium numeric; v_goals numeric; v_applied numeric; v_need numeric; v_lines int;
  v_income numeric; v_untaxed numeric; v_noncash numeric;
begin
  foreach lv in array array['current', 'survival', 'stability', 'aspirational'] loop
    with l_all as (select * from mirror.dn_lines(p, v_as_of)),
    res as (select * from l_all where kind in ('income', 'noncash') and (applies is null or cardinality(applies) = 0 or lv = any (applies))),
    lines as (select * from l_all where kind in ('expense', 'goal') and (level = lv or (lv = 'aspirational' and level = 'stability'))),
    nc as (select cat, sum(y) y from res where kind = 'noncash' group by 1),
    cash_cat as (select cat, sum(y) y from lines where paid_by = 'self' group by 1)
    select (count(*) filter (where not goal))::int, coalesce(sum(y), 0), coalesce(sum(y) filter (where paid_by = 'self'), 0),
           coalesce(sum(y) filter (where paid_by <> 'self'), 0), coalesce(sum(y) filter (where premium), 0), coalesce(sum(y) filter (where goal), 0),
           (select coalesce(sum(least(c.y, coalesce(n.y, 0))), 0) from cash_cat c left join nc n on n.cat = c.cat),
           (select coalesce(sum(y), 0) from res where kind = 'income'),
           (select coalesce(sum(y), 0) from res where kind = 'income' and not taxable),
           (select coalesce(sum(y), 0) from res where kind = 'noncash')
      into v_lines, v_cost, v_cash, v_others, v_premium, v_goals, v_applied, v_income, v_untaxed, v_noncash
      from lines;
    v_need := v_cash - v_applied;
    v_levels := v_levels || jsonb_build_object(lv, jsonb_build_object(
      'lines', v_lines, 'cost', mirror.per(v_cost), 'cash_expenses', mirror.per(v_cash), 'paid_by_others', mirror.per(v_others),
      'noncash_applied', mirror.per(v_applied), 'cash_needed', mirror.per(v_need), 'shortfall', mirror.per(greatest(0, v_need - v_income)),
      'gross_needed', mirror.per(greatest(0, v_need - v_untaxed) / (1 - v_tax)), 'poverty_premium', mirror.per(v_premium), 'goals', mirror.per(v_goals),
      'income', mirror.per(v_income), 'untaxed_income', mirror.per(v_untaxed), 'noncash', mirror.per(v_noncash),
      'resources', mirror.per(v_income + v_applied + v_others)));
  end loop;
  return jsonb_build_object('method', 4, 'as_of', v_as_of, 'tax_rate_pct', v_tax * 100,
    'income', v_levels #> '{current,income}', 'noncash', v_levels #> '{current,noncash}', 'levels', v_levels);
end $function$;

-- The automatic save recorded method 3 by hand; it now records the method its numbers were calculated with.
CREATE OR REPLACE FUNCTION mirror.dn_auto_snapshot(p_individual uuid, p_role text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  inp jsonb;
  res jsonb;
  last mirror.daily_number_snapshots;
  v_changed date;   -- the day the numbers were last changed (Milwaukee time)
begin
  select (max(t) at time zone 'America/Chicago')::date into v_changed from (
    select greatest(created_at, updated_at) t from mirror.living_expenses where individual_id = p_individual
    union all select greatest(created_at, updated_at) from mirror.income_sources where individual_id = p_individual
    union all select greatest(created_at, updated_at) from mirror.noncash_resources where individual_id = p_individual
    union all select greatest(created_at, updated_at) from mirror.financial_goals where individual_id = p_individual
    union all select updated_at from mirror.daily_number_settings where individual_id = p_individual) x;
  -- Only when the numbers on screen are from an earlier day: then they are that day's final numbers, worth keeping.
  -- A list still being built today is never saved automatically.
  if v_changed is null or v_changed >= mirror.today_local() then return; end if;
  inp := mirror.daily_number_inputs(p_individual);
  select * into last from mirror.daily_number_snapshots where individual_id = p_individual order by taken_at desc limit 1;
  if found and ((last.taken_at at time zone 'America/Chicago')::date >= v_changed or (last.inputs - 'as_of') = (inp - 'as_of')) then
    return;   -- those numbers were already saved, or nothing differs from the last save
  end if;
  res := mirror.daily_number_calc(inp);
  insert into mirror.daily_number_snapshots (individual_id, method_version, inputs, results, note, taken_by, taken_by_role)
  values (p_individual, (res ->> 'method')::int, inp, res, 'Saved automatically: your numbers as they were on '
          || to_char(v_changed, 'FMMonth FMDD, YYYY'), coalesce(lower(auth.email()), 'system'), coalesce(p_role, 'self'));
end $function$;

-- ---------------------------------------------------------------- grants (same as the other Daily Number functions: server only)
revoke all on function mirror.dn_end_on(jsonb) from public, anon, authenticated;
grant execute on function mirror.dn_end_on(jsonb) to service_role;
