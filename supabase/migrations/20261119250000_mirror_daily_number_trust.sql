-- The Human Mirror, Phase 4 step 2 "make it trustworthy" (Stephen, 11/13/2026). Method version 3, same arithmetic as daily-number.js.
--  1. Income and help that isn't cash count only in the levels they apply to (applies_to; null or empty = all four), so the gap at
--     Stability can leave out SNAP that would stop, or include a job that will start. Pages warn about benefits that may drop.
--  2. Income can be marked taxed or not (taxable; null = by kind: wages, own work, pensions are taxed; SSI-type benefits, gifts and
--     other are not). Income needed before taxes = (cash needed - untaxed income) / (1 - tax rate).
--  3. One "resources" figure per level = cash income + help that isn't cash used + costs paid for the person (the paper's $75 / $25 / $50).
--  4. History: the first change on a new day first saves the numbers as they were (automatic save), so no day's numbers are lost.
--     Saved numbers now record the method version they were calculated with (they always said 1).

alter table mirror.income_sources add column applies_to text[] check (applies_to is null or applies_to <@ array['current', 'survival', 'stability', 'aspirational']),
  add column taxable boolean;
alter table mirror.noncash_resources add column applies_to text[] check (applies_to is null or applies_to <@ array['current', 'survival', 'stability', 'aspirational']);

-- ---------------------------------------------------------------- inputs and lines

create or replace function mirror.daily_number_inputs(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object(
    'as_of', mirror.today_local(),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'level', e.level, 'category', e.category, 'label', e.label, 'amount', e.amount,
        'frequency', e.frequency, 'times_per_year', e.times_per_year, 'spread_months', e.spread_months, 'paid_by', e.paid_by,
        'poverty_premium', e.poverty_premium, 'note', e.note, 'start_on', e.start_on, 'end_on', e.end_on) order by e.level, e.category, e.label)
      from mirror.living_expenses e where e.individual_id = p_individual and e.active), '[]'::jsonb),
    'income', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'label', i.label, 'amount', i.amount, 'frequency', i.frequency,
        'times_per_year', i.times_per_year, 'spread_months', i.spread_months, 'note', i.note, 'start_on', i.start_on, 'end_on', i.end_on,
        'applies_to', i.applies_to, 'taxable', i.taxable) order by i.kind, i.label)
      from mirror.income_sources i where i.individual_id = p_individual and i.active), '[]'::jsonb),
    'noncash', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'category', n.category, 'label', n.label, 'amount', n.amount,
        'frequency', n.frequency, 'times_per_year', n.times_per_year, 'spread_months', n.spread_months, 'note', n.note, 'start_on', n.start_on, 'end_on', n.end_on,
        'applies_to', n.applies_to) order by n.kind, n.label)
      from mirror.noncash_resources n where n.individual_id = p_individual and n.active), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'label', g.label, 'level', g.level, 'target_amount', g.target_amount,
        'current_amount', g.current_amount, 'target_date', g.target_date) order by g.created_at)
      from mirror.financial_goals g where g.individual_id = p_individual), '[]'::jsonb),
    'tax_rate_pct', coalesce((select s.tax_rate_pct from mirror.daily_number_settings s where s.individual_id = p_individual), 0));
$$;

-- The calculation now needs, for income and help: which levels each applies to, and for income whether it is taxed.
drop function if exists mirror.daily_number_calc(jsonb);
drop function if exists mirror.dn_lines(jsonb, date);
create function mirror.dn_lines(p jsonb, p_as_of date)
returns table (kind text, level text, cat text, paid_by text, premium boolean, goal boolean, y numeric, applies text[], taxable boolean)
language sql immutable set search_path = mirror, public as $f$
  select 'expense', x ->> 'level', x ->> 'category', x ->> 'paid_by', coalesce((x ->> 'poverty_premium')::boolean, false), false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int), null::text[], null::boolean
  from jsonb_array_elements(coalesce(p -> 'expenses', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (nullif(x ->> 'end_on', '') is null or (x ->> 'end_on')::date >= p_as_of)
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
    and (nullif(x ->> 'end_on', '') is null or (x ->> 'end_on')::date >= p_as_of)
  union all
  select 'noncash', null, x ->> 'category', null, false, false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int),
         case when jsonb_typeof(x -> 'applies_to') = 'array' then array(select jsonb_array_elements_text(x -> 'applies_to')) end, null
  from jsonb_array_elements(coalesce(p -> 'noncash', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (nullif(x ->> 'end_on', '') is null or (x ->> 'end_on')::date >= p_as_of);
$f$;

create function mirror.daily_number_calc(p jsonb) returns jsonb
language plpgsql stable set search_path = mirror, public as $$
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
  return jsonb_build_object('method', 3, 'as_of', v_as_of, 'tax_rate_pct', v_tax * 100,
    'income', v_levels #> '{current,income}', 'noncash', v_levels #> '{current,noncash}', 'levels', v_levels);
end $$;

create or replace function mirror.daily_number(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select mirror.daily_number_calc(mirror.daily_number_inputs(p_individual));
$$;

-- ---------------------------------------------------------------- automatic save before the first change of a day

create or replace function mirror.dn_auto_snapshot(p_individual uuid, p_role text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare
  inp jsonb;
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
  insert into mirror.daily_number_snapshots (individual_id, method_version, inputs, results, note, taken_by, taken_by_role)
  values (p_individual, 3, inp, mirror.daily_number_calc(inp), 'Saved automatically: your numbers as they were on '
          || to_char(v_changed, 'FMMonth FMDD, YYYY'), coalesce(lower(auth.email()), 'system'), coalesce(p_role, 'self'));
end $$;

-- ---------------------------------------------------------------- saving (adds applies_to, taxable, the automatic save)

create or replace function public.mirror_dn_save(p_kind text, p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.target_individual(p_individual);
  g jsonb;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_label text := nullif(btrim(coalesce(p ->> 'label', '')), '');
  v_amount numeric;
  v_freq text := coalesce(nullif(p ->> 'frequency', ''), 'monthly');
  v_times numeric := nullif(p ->> 'times_per_year', '')::numeric;
  v_spread int := nullif(p ->> 'spread_months', '')::int;
  v_start date;
  v_end date;
  v_applies text[] := case when jsonb_typeof(p -> 'applies_to') = 'array' and jsonb_array_length(p -> 'applies_to') between 1 and 3
                           then array(select jsonb_array_elements_text(p -> 'applies_to')) end;   -- all four (or none) = null = all levels
  v_taxable boolean := case when p ->> 'taxable' in ('true', 'false') then (p ->> 'taxable')::boolean end;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  begin v_start := nullif(p ->> 'start_on', '')::date; v_end := nullif(p ->> 'end_on', '')::date;
  exception when others then raise exception 'One of the dates is not a real date.' using errcode = '22023'; end;
  if p_kind in ('expense', 'income', 'noncash') then
    begin v_amount := round(replace(replace(coalesce(p ->> 'amount', ''), '$', ''), ',', '')::numeric, 2);
    exception when others then raise exception 'Enter an amount, for example 120 or 45.50.' using errcode = '22023'; end;
    if v_label is null then raise exception 'Give it a short name, for example "Rent".' using errcode = '22023'; end if;
    if v_freq = 'irregular' and v_times is null then raise exception 'How many times a year?' using errcode = '22023'; end if;
    if v_start is not null and v_end is not null and v_end < v_start then raise exception 'The end date is before the start date.' using errcode = '22023'; end if;
  end if;
  perform mirror.dn_auto_snapshot(v, g ->> 'role');
  if p_kind = 'expense' then
    if v_id is null then
      insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note, start_on, end_on)
      values (v, p ->> 'level', p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, coalesce(nullif(p ->> 'paid_by', ''), 'self'),
              coalesce((p ->> 'poverty_premium')::boolean, false), nullif(btrim(p ->> 'note'), ''), v_start, v_end);
    else
      update mirror.living_expenses set level = p ->> 'level', category = p ->> 'category', label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, paid_by = coalesce(nullif(p ->> 'paid_by', ''), 'self'),
        poverty_premium = coalesce((p ->> 'poverty_premium')::boolean, false), note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'income' then
    if v_id is null then
      insert into mirror.income_sources (individual_id, kind, label, amount, frequency, times_per_year, spread_months, note, start_on, end_on, applies_to, taxable)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''), v_start, v_end, v_applies, v_taxable);
    else
      update mirror.income_sources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end,
        applies_to = v_applies, taxable = v_taxable
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'noncash' then
    if v_id is null then
      insert into mirror.noncash_resources (individual_id, kind, category, label, amount, frequency, times_per_year, spread_months, note, start_on, end_on, applies_to)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''), v_start, v_end, v_applies);
    else
      update mirror.noncash_resources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), category = p ->> 'category', label = v_label, amount = v_amount,
        frequency = v_freq, times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end,
        applies_to = v_applies
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'goal' then
    if v_label is null then raise exception 'Give the goal a name.' using errcode = '22023'; end if;
    if v_id is null then
      insert into mirror.financial_goals (individual_id, kind, label, level, target_amount, current_amount, target_date)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'savings'), v_label, coalesce(nullif(p ->> 'level', ''), 'stability'),
              nullif(p ->> 'target_amount', '')::numeric, coalesce(nullif(p ->> 'current_amount', '')::numeric, 0), nullif(p ->> 'target_date', '')::date);
    else
      update mirror.financial_goals set kind = coalesce(nullif(p ->> 'kind', ''), 'savings'), label = v_label, level = coalesce(nullif(p ->> 'level', ''), 'stability'),
        target_amount = nullif(p ->> 'target_amount', '')::numeric, current_amount = coalesce(nullif(p ->> 'current_amount', '')::numeric, 0),
        target_date = nullif(p ->> 'target_date', '')::date
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'settings' then
    insert into mirror.daily_number_settings (individual_id, tax_rate_pct, household_size)
    values (v, coalesce(nullif(p ->> 'tax_rate_pct', '')::numeric, 0), nullif(p ->> 'household_size', '')::int)
    on conflict (individual_id) do update set tax_rate_pct = excluded.tax_rate_pct, household_size = excluded.household_size, updated_at = now();
  else
    raise exception 'Unknown record.' using errcode = '22023';
  end if;
  return mirror.daily_number(v);
exception
  when check_violation then raise exception 'Something in that entry is not allowed (check the amount, how often, the dates and the choices).' using errcode = '22023';
  when foreign_key_violation then raise exception 'Choose a category from the list.' using errcode = '22023';
  when not_null_violation then raise exception 'Something is missing: choose the level, the category and how often.' using errcode = '22023';
  when invalid_datetime_format or datetime_field_overflow then raise exception 'One of the dates is not a real date.' using errcode = '22023';
end $$;

create or replace function public.mirror_dn_delete(p_kind text, p_id uuid, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  perform mirror.dn_auto_snapshot(v, g ->> 'role');
  if p_kind = 'expense' then delete from mirror.living_expenses where id = p_id and individual_id = v;
  elsif p_kind = 'income' then delete from mirror.income_sources where id = p_id and individual_id = v;
  elsif p_kind = 'noncash' then delete from mirror.noncash_resources where id = p_id and individual_id = v;
  elsif p_kind = 'goal' then delete from mirror.financial_goals where id = p_id and individual_id = v;
  else raise exception 'Unknown record.' using errcode = '22023'; end if;
  if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return mirror.daily_number(v);
end $$;

create or replace function public.mirror_dn_copy(p_from text, p_to text, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); n int; g jsonb;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number', 'copy');
  if p_from not in ('current', 'survival', 'stability', 'aspirational') or p_to not in ('current', 'survival', 'stability', 'aspirational') or p_from = p_to then
    raise exception 'Choose two different lists.' using errcode = '22023';
  end if;
  perform mirror.dn_auto_snapshot(v, g ->> 'role');
  insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note, start_on, end_on)
  select individual_id, p_to, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note, start_on, end_on
  from mirror.living_expenses where individual_id = v and level = p_from and active;
  get diagnostics n = row_count;
  return jsonb_build_object('copied', n, 'results', mirror.daily_number(v));
end $$;

-- Saved numbers record the method they were calculated with.
create or replace function public.mirror_dn_snapshot(p_note text default null, p_individual uuid default null) returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb; inp jsonb; res jsonb; v_id uuid;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number_snapshots', null);
  inp := mirror.daily_number_inputs(v);
  res := mirror.daily_number_calc(inp);
  insert into mirror.daily_number_snapshots (individual_id, method_version, inputs, results, note, taken_by, taken_by_role)
  values (v, (res ->> 'method')::int, inp, res, nullif(btrim(p_note), ''), lower(auth.email()), g ->> 'role') returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- grants

revoke all on function mirror.dn_lines(jsonb, date), mirror.daily_number_calc(jsonb), mirror.dn_auto_snapshot(uuid, text) from public, anon, authenticated;
grant execute on function mirror.dn_lines(jsonb, date), mirror.daily_number_calc(jsonb), mirror.dn_auto_snapshot(uuid, text) to service_role;
