-- The Human Mirror, Phase 4 fixes (Stephen 11/13/2026: "fix what's wrong or broken now"):
--  1. "Download everything" now includes the Daily Number (costs, income, help that isn't cash, goals, settings, saved numbers).
--  2. Copying a list to another level is one all-or-nothing step (mirror_dn_copy) instead of one call per line.
--  3. Start and end dates on costs, income and help that isn't cash: a line counts only while in effect on the "as of" day
--     (today in Milwaukee time). Lines that start later or have ended stay listed, so pages can show what's coming and what ended.
--  4. Savings goals count: (target - saved) / months left (ceil(days x 12 / 365)) is a monthly saving in the level the person
--     chooses (Stability, The life I want, or not counted).
-- Method version 2. Same arithmetic as site/mirror/assets/daily-number.js, checked against the same hand-worked fixtures (t42).

alter table mirror.living_expenses add column start_on date, add column end_on date,
  add constraint living_expenses_dates check (start_on is null or end_on is null or end_on >= start_on);
alter table mirror.income_sources add column start_on date, add column end_on date,
  add constraint income_sources_dates check (start_on is null or end_on is null or end_on >= start_on);
alter table mirror.noncash_resources add column start_on date, add column end_on date,
  add constraint noncash_resources_dates check (start_on is null or end_on is null or end_on >= start_on);
alter table mirror.financial_goals add column level text not null default 'stability' check (level in ('stability', 'aspirational', 'none'));

create or replace function mirror.today_local() returns date
language sql stable as $$ select (now() at time zone 'America/Chicago')::date; $$;

create or replace function mirror.goal_monthly(p_target numeric, p_current numeric, p_date date, p_as_of date) returns numeric
language sql immutable as $$
  select case when coalesce(p_target, 0) - coalesce(p_current, 0) <= 0 or p_date is null or p_date - p_as_of <= 0 then 0
              else (coalesce(p_target, 0) - coalesce(p_current, 0)) / ceil((p_date - p_as_of) * 12 / 365.0) end;
$$;

-- Inputs: every active line (also future and ended ones; the calculation picks those in effect), the goals, the tax rate, the day.
create or replace function mirror.daily_number_inputs(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object(
    'as_of', mirror.today_local(),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'level', e.level, 'category', e.category, 'label', e.label, 'amount', e.amount,
        'frequency', e.frequency, 'times_per_year', e.times_per_year, 'spread_months', e.spread_months, 'paid_by', e.paid_by,
        'poverty_premium', e.poverty_premium, 'note', e.note, 'start_on', e.start_on, 'end_on', e.end_on) order by e.level, e.category, e.label)
      from mirror.living_expenses e where e.individual_id = p_individual and e.active), '[]'::jsonb),
    'income', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'label', i.label, 'amount', i.amount, 'frequency', i.frequency,
        'times_per_year', i.times_per_year, 'spread_months', i.spread_months, 'note', i.note, 'start_on', i.start_on, 'end_on', i.end_on) order by i.kind, i.label)
      from mirror.income_sources i where i.individual_id = p_individual and i.active), '[]'::jsonb),
    'noncash', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'category', n.category, 'label', n.label, 'amount', n.amount,
        'frequency', n.frequency, 'times_per_year', n.times_per_year, 'spread_months', n.spread_months, 'note', n.note, 'start_on', n.start_on, 'end_on', n.end_on)
        order by n.kind, n.label)
      from mirror.noncash_resources n where n.individual_id = p_individual and n.active), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'label', g.label, 'level', g.level, 'target_amount', g.target_amount,
        'current_amount', g.current_amount, 'target_date', g.target_date) order by g.created_at)
      from mirror.financial_goals g where g.individual_id = p_individual), '[]'::jsonb),
    'tax_rate_pct', coalesce((select s.tax_rate_pct from mirror.daily_number_settings s where s.individual_id = p_individual), 0));
$$;

-- Every line in effect on the day, as rows: expenses, goals (as monthly savings), income, help that isn't cash.
create or replace function mirror.dn_lines(p jsonb, p_as_of date)
returns table (kind text, level text, cat text, paid_by text, premium boolean, goal boolean, y numeric)
language sql immutable set search_path = mirror, public as $f$
  select 'expense', x ->> 'level', x ->> 'category', x ->> 'paid_by', coalesce((x ->> 'poverty_premium')::boolean, false), false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int)
  from jsonb_array_elements(coalesce(p -> 'expenses', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (nullif(x ->> 'end_on', '') is null or (x ->> 'end_on')::date >= p_as_of)
  union all
  select 'goal', coalesce(g ->> 'level', 'stability'), 'future', 'self', false, true,
         12 * mirror.goal_monthly((g ->> 'target_amount')::numeric, (g ->> 'current_amount')::numeric, nullif(g ->> 'target_date', '')::date, p_as_of)
  from jsonb_array_elements(coalesce(p -> 'goals', '[]')) g
  where coalesce(g ->> 'level', 'stability') <> 'none'
    and mirror.goal_monthly((g ->> 'target_amount')::numeric, (g ->> 'current_amount')::numeric, nullif(g ->> 'target_date', '')::date, p_as_of) > 0
  union all
  select 'income', null, null, null, false, false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int)
  from jsonb_array_elements(coalesce(p -> 'income', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (nullif(x ->> 'end_on', '') is null or (x ->> 'end_on')::date >= p_as_of)
  union all
  select 'noncash', null, x ->> 'category', null, false, false,
         mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int)
  from jsonb_array_elements(coalesce(p -> 'noncash', '[]')) x
  where coalesce((x ->> 'active')::boolean, true)
    and (nullif(x ->> 'start_on', '') is null or (x ->> 'start_on')::date <= p_as_of)
    and (nullif(x ->> 'end_on', '') is null or (x ->> 'end_on')::date >= p_as_of);
$f$;

create or replace function mirror.daily_number_calc(p jsonb) returns jsonb
language plpgsql stable set search_path = mirror, public as $$
declare
  v_as_of date := coalesce(nullif(p ->> 'as_of', '')::date, (now() at time zone 'America/Chicago')::date);
  v_tax numeric := least(greatest(coalesce((p ->> 'tax_rate_pct')::numeric, 0), 0), 90) / 100;
  v_income numeric;
  v_noncash numeric;
  v_levels jsonb := '{}'::jsonb;
  lv text;
  v_cost numeric; v_cash numeric; v_others numeric; v_premium numeric; v_goals numeric; v_applied numeric; v_need numeric; v_lines int;
begin
  select coalesce(sum(y), 0) into v_income from mirror.dn_lines(p, v_as_of) where kind = 'income';
  select coalesce(sum(y), 0) into v_noncash from mirror.dn_lines(p, v_as_of) where kind = 'noncash';
  foreach lv in array array['current', 'survival', 'stability', 'aspirational'] loop
    with l_all as (select * from mirror.dn_lines(p, v_as_of)),
    lines as (select * from l_all where kind in ('expense', 'goal') and (level = lv or (lv = 'aspirational' and level = 'stability'))),
    nc as (select cat, sum(y) y from l_all where kind = 'noncash' group by 1),
    cash_cat as (select cat, sum(y) y from lines where paid_by = 'self' group by 1)
    select (count(*) filter (where not goal))::int, coalesce(sum(y), 0), coalesce(sum(y) filter (where paid_by = 'self'), 0),
           coalesce(sum(y) filter (where paid_by <> 'self'), 0), coalesce(sum(y) filter (where premium), 0), coalesce(sum(y) filter (where goal), 0),
           (select coalesce(sum(least(c.y, coalesce(n.y, 0))), 0) from cash_cat c left join nc n on n.cat = c.cat)
      into v_lines, v_cost, v_cash, v_others, v_premium, v_goals, v_applied
      from lines;
    v_need := v_cash - v_applied;
    v_levels := v_levels || jsonb_build_object(lv, jsonb_build_object(
      'lines', v_lines, 'cost', mirror.per(v_cost), 'cash_expenses', mirror.per(v_cash), 'paid_by_others', mirror.per(v_others),
      'noncash_applied', mirror.per(v_applied), 'cash_needed', mirror.per(v_need), 'shortfall', mirror.per(greatest(0, v_need - v_income)),
      'gross_needed', mirror.per(v_need / (1 - v_tax)), 'poverty_premium', mirror.per(v_premium), 'goals', mirror.per(v_goals)));
  end loop;
  return jsonb_build_object('method', 2, 'as_of', v_as_of, 'tax_rate_pct', v_tax * 100, 'income', mirror.per(v_income),
    'noncash', mirror.per(v_noncash), 'levels', v_levels);
end $$;

-- ---------------------------------------------------------------- saving: dates on lines, the level of a goal

create or replace function public.mirror_dn_save(p_kind text, p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.target_individual(p_individual);
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_label text := nullif(btrim(coalesce(p ->> 'label', '')), '');
  v_amount numeric;
  v_freq text := coalesce(nullif(p ->> 'frequency', ''), 'monthly');
  v_times numeric := nullif(p ->> 'times_per_year', '')::numeric;
  v_spread int := nullif(p ->> 'spread_months', '')::int;
  v_start date;
  v_end date;
begin
  perform mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  begin v_start := nullif(p ->> 'start_on', '')::date; v_end := nullif(p ->> 'end_on', '')::date;
  exception when others then raise exception 'One of the dates is not a real date.' using errcode = '22023'; end;
  if p_kind in ('expense', 'income', 'noncash') then
    begin v_amount := round(replace(replace(coalesce(p ->> 'amount', ''), '$', ''), ',', '')::numeric, 2);
    exception when others then raise exception 'Enter an amount, for example 120 or 45.50.' using errcode = '22023'; end;
    if v_label is null then raise exception 'Give it a short name, for example "Rent".' using errcode = '22023'; end if;
    if v_freq = 'irregular' and v_times is null then raise exception 'How many times a year?' using errcode = '22023'; end if;
    if v_start is not null and v_end is not null and v_end < v_start then raise exception 'The end date is before the start date.' using errcode = '22023'; end if;
  end if;
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
      insert into mirror.income_sources (individual_id, kind, label, amount, frequency, times_per_year, spread_months, note, start_on, end_on)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''), v_start, v_end);
    else
      update mirror.income_sources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'noncash' then
    if v_id is null then
      insert into mirror.noncash_resources (individual_id, kind, category, label, amount, frequency, times_per_year, spread_months, note, start_on, end_on)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''), v_start, v_end);
    else
      update mirror.noncash_resources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), category = p ->> 'category', label = v_label, amount = v_amount,
        frequency = v_freq, times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end
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

-- Copy every line of one list into another, all or nothing (one statement). Returns how many were copied and the new results.
create or replace function public.mirror_dn_copy(p_from text, p_to text, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); n int;
begin
  perform mirror.require(v, 'financial', 'edit', null, 'daily_number', 'copy');
  if p_from not in ('current', 'survival', 'stability', 'aspirational') or p_to not in ('current', 'survival', 'stability', 'aspirational') or p_from = p_to then
    raise exception 'Choose two different lists.' using errcode = '22023';
  end if;
  insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note, start_on, end_on)
  select individual_id, p_to, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note, start_on, end_on
  from mirror.living_expenses where individual_id = v and level = p_from and active;
  get diagnostics n = row_count;
  return jsonb_build_object('copied', n, 'results', mirror.daily_number(v));
end $$;

-- ---------------------------------------------------------------- the download now includes the Daily Number

create or replace function public.mirror_my_export() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); r jsonb;
begin
  r := jsonb_build_object(
    'exported_at', now(),
    'about', 'Your Human Mirror, downloaded from 2nd Chance Housing Inc. It is yours.',
    'me', (select jsonb_build_object('preferred_name', preferred_name, 'legal_name', legal_name, 'birth_year', birth_year, 'email', auth_email,
        'safety_mode', safety_sensitive, 'created_at', created_at) from mirror.individuals where id = v),
    'organizations', public.mirror_my_settings() -> 'organizations',
    'sharing_history', coalesce((select jsonb_agg(jsonb_build_object('organization', o.name, 'topic', c.category, 'access', c.access,
        'given', c.granted_at, 'withdrawn', c.revoked_at) order by c.granted_at)
      from mirror.consents c join mirror.organizations o on o.id = c.organization_id where c.individual_id = v), '[]'::jsonb),
    'answers', coalesce((select jsonb_agg(jsonb_build_object('set', s.title, 'set_key', s.key, 'question', q.prompt, 'question_key', q.key,
        'answer', x.value, 'state', x.state, 'note', x.note, 'by', x.answered_by_role, 'at', x.answered_at, 'current', x.superseded_at is null)
        order by s.kind, s.sort, q.sort, x.answered_at)
      from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
      join mirror.question_sets s on s.id = a.set_id join mirror.reflection_questions q on q.id = x.question_id
      where a.individual_id = v), '[]'::jsonb),
    'daily_number', jsonb_build_object(
      'inputs', mirror.daily_number_inputs(v),
      'household_size', (select household_size from mirror.daily_number_settings where individual_id = v),
      'results', mirror.daily_number(v),
      'saved', coalesce((select jsonb_agg(jsonb_build_object('taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role, 'inputs', s.inputs, 'results', s.results)
          order by s.taken_at) from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb)),
    'who_looked', public.mirror_who_looked());
  perform mirror.audit(v, null, 'self', 'export', 'general', 'individuals', null);
  return r;
end $$;

-- ---------------------------------------------------------------- grants for the new functions

revoke all on function mirror.today_local(), mirror.goal_monthly(numeric, numeric, date, date), mirror.dn_lines(jsonb, date) from public, anon, authenticated;
grant execute on function mirror.today_local(), mirror.goal_monthly(numeric, numeric, date, date), mirror.dn_lines(jsonb, date) to service_role;
revoke all on function public.mirror_dn_copy(text, text, uuid) from public, anon;
grant execute on function public.mirror_dn_copy(text, text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- the page data now carries each goal's level and the day used

create or replace function public.mirror_dn_get(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; inp jsonb;
begin
  r := mirror.allowed(v, 'financial', 'view', null, 'daily_number', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  inp := mirror.daily_number_inputs(v);
  return jsonb_build_object(
    'can_edit', mirror.may(v, 'financial', 'edit'),
    'categories', (select jsonb_agg(jsonb_build_object('key', key, 'title', title, 'examples', examples) order by sort) from mirror.expense_categories),
    'inputs', inp,
    'household_size', (select household_size from mirror.daily_number_settings where individual_id = v),
    'goals', inp -> 'goals',
    'results', mirror.daily_number_calc(inp),
    'snapshots', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role,
        'current_daily', s.results #> '{levels,current,cost,daily}', 'stability_daily', s.results #> '{levels,stability,cost,daily}') order by s.taken_at desc)
      from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb));
end $$;
