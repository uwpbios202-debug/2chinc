-- The Human Mirror T4.2 (+ T4.4 marker): the Daily Number as a living financial record (prompt Part 4; Stephen's Daily Number paper).
-- The arithmetic is site/mirror/assets/daily-number.js (D-08) repeated exactly in mirror.daily_number(); both are checked against the
-- same hand-worked fixtures (tools/mirror-checks/daily-number-fixtures.mjs and t42-daily-number-check.sql).
--
-- Everything here is the person's "financial" topic (D-14): the person always; a coordinator only when the person shares money.
-- Records kept apart on purpose (prompt: "do not treat SNAP, donated food, housing assistance and wages as interchangeable income"):
--   living_expenses   each cost, its level, category, frequency and WHO PAYS (self / subsidy / assistance / donated)
--   income_sources    cash income only (take-home)
--   noncash_resources SNAP, WIC, donated goods and services, coverage: lowers costs in its own category only
--   financial_goals   savings, emergency reserve, debt payoff, retirement, purchases
--   daily_number_settings  tax rate the person enters (none assumed), household size
--   daily_number_snapshots dated copies of inputs + results ("how the number changes over time"); never changed

create table mirror.expense_categories (
  key text primary key,
  title text not null,
  examples text not null,
  sort int not null
);
insert into mirror.expense_categories (key, title, examples, sort) values
  ('housing', 'Housing', 'Rent, mortgage, property costs', 1), ('utilities', 'Utilities', 'Electricity, gas, water', 2),
  ('food', 'Food', 'Groceries, meals, drinking water', 3), ('transportation', 'Transportation', 'Transit, fuel, vehicle costs', 4),
  ('healthcare', 'Healthcare', 'Insurance, medication, appointments', 5), ('personal_care', 'Personal care', 'Hygiene, haircuts, toiletries', 6),
  ('clothing', 'Clothing', 'Everyday clothing, shoes, replacement', 7), ('communication', 'Communication', 'Phone, internet, devices', 8),
  ('household', 'Household', 'Cleaning, laundry, furnishings', 9), ('financial', 'Financial', 'Banking, debt payments, fees', 10),
  ('development', 'Personal development', 'Education, training, recreation', 11), ('future', 'Future security', 'Savings, emergency fund, retirement', 12);

create table mirror.living_expenses (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  level text not null check (level in ('current', 'survival', 'stability', 'aspirational')),
  category text not null references mirror.expense_categories(key),
  label text not null check (length(label) between 1 and 120),
  amount numeric(12,2) not null check (amount >= 0 and amount <= 10000000),
  frequency text not null check (frequency in ('daily', 'weekly', 'biweekly', 'twice_month', 'monthly', 'quarterly', 'annual', 'irregular', 'one_time')),
  times_per_year numeric(8,2) check (times_per_year is null or times_per_year > 0),
  spread_months int check (spread_months is null or spread_months between 1 and 120),
  paid_by text not null default 'self' check (paid_by in ('self', 'subsidy', 'assistance', 'donated')),
  poverty_premium boolean not null default false,          -- T4.4: "a cost of being poor" that could go down
  note text check (note is null or length(note) <= 500),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (frequency <> 'irregular' or times_per_year is not null)
);
create index living_expenses_person on mirror.living_expenses (individual_id);

create table mirror.income_sources (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  kind text not null check (kind in ('wages', 'self_employment', 'cash_benefit', 'pension', 'family_support', 'other')),
  label text not null check (length(label) between 1 and 120),
  amount numeric(12,2) not null check (amount >= 0 and amount <= 10000000),
  frequency text not null check (frequency in ('daily', 'weekly', 'biweekly', 'twice_month', 'monthly', 'quarterly', 'annual', 'irregular', 'one_time')),
  times_per_year numeric(8,2) check (times_per_year is null or times_per_year > 0),
  spread_months int check (spread_months is null or spread_months between 1 and 120),
  note text check (note is null or length(note) <= 500),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (frequency <> 'irregular' or times_per_year is not null)
);
create index income_sources_person on mirror.income_sources (individual_id);

create table mirror.noncash_resources (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  kind text not null check (kind in ('snap', 'wic', 'donated_goods', 'donated_services', 'healthcare_coverage', 'other')),
  category text not null references mirror.expense_categories(key),
  label text not null check (length(label) between 1 and 120),
  amount numeric(12,2) not null check (amount >= 0 and amount <= 10000000),   -- estimated value
  frequency text not null check (frequency in ('daily', 'weekly', 'biweekly', 'twice_month', 'monthly', 'quarterly', 'annual', 'irregular', 'one_time')),
  times_per_year numeric(8,2) check (times_per_year is null or times_per_year > 0),
  spread_months int check (spread_months is null or spread_months between 1 and 120),
  note text check (note is null or length(note) <= 500),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (frequency <> 'irregular' or times_per_year is not null)
);
create index noncash_resources_person on mirror.noncash_resources (individual_id);

create table mirror.financial_goals (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  kind text not null check (kind in ('emergency_reserve', 'savings', 'debt_payoff', 'retirement', 'purchase', 'other')),
  label text not null check (length(label) between 1 and 120),
  target_amount numeric(12,2) check (target_amount is null or target_amount >= 0),
  current_amount numeric(12,2) not null default 0 check (current_amount >= 0),
  target_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index financial_goals_person on mirror.financial_goals (individual_id);

create table mirror.daily_number_settings (
  individual_id uuid primary key references mirror.individuals(id) on delete cascade,
  tax_rate_pct numeric(5,2) not null default 0 check (tax_rate_pct between 0 and 90),
  household_size int check (household_size is null or household_size between 1 and 20),
  updated_at timestamptz not null default now()
);

create table mirror.daily_number_snapshots (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  taken_at timestamptz not null default now(),
  method_version int not null,
  inputs jsonb not null,
  results jsonb not null,
  note text check (note is null or length(note) <= 500),
  taken_by text not null,
  taken_by_role text not null
);
create index daily_number_snapshots_person on mirror.daily_number_snapshots (individual_id, taken_at desc);
create or replace function mirror.snapshots_never_change() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from mirror.individuals i where i.id = old.individual_id) then return old; end if;
  raise exception 'Saved Daily Numbers are never changed; save a new one instead.' using errcode = '42501';
end $$;
create trigger daily_number_snapshots_never_change before update or delete on mirror.daily_number_snapshots
  for each row execute function mirror.snapshots_never_change();

-- ---------------------------------------------------------------- the calculation (same as daily-number.js, D-08)

create or replace function mirror.annual_of(p_amount numeric, p_frequency text, p_times numeric, p_spread int) returns numeric
language sql immutable as $$
  select case p_frequency
    when 'daily' then p_amount * 365
    when 'weekly' then p_amount * 365 / 7
    when 'biweekly' then p_amount * 365 / 14
    when 'twice_month' then p_amount * 24
    when 'monthly' then p_amount * 12
    when 'quarterly' then p_amount * 4
    when 'annual' then p_amount
    when 'irregular' then p_amount * coalesce(p_times, 0)
    when 'one_time' then p_amount * 12 / greatest(coalesce(p_spread, 12), 12)
    else 0 end;
$$;

create or replace function mirror.per(p_annual numeric) returns jsonb
language sql immutable as $$
  select jsonb_build_object('annual', p_annual, 'daily', p_annual / 365, 'weekly', p_annual / 365 * 7, 'monthly', p_annual / 12);
$$;

-- The inputs as one JSON (also what a snapshot stores): {expenses, income, noncash, tax_rate_pct} with active lines only.
create or replace function mirror.daily_number_inputs(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object(
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'level', e.level, 'category', e.category, 'label', e.label, 'amount', e.amount,
        'frequency', e.frequency, 'times_per_year', e.times_per_year, 'spread_months', e.spread_months, 'paid_by', e.paid_by,
        'poverty_premium', e.poverty_premium, 'note', e.note) order by e.level, e.category, e.label)
      from mirror.living_expenses e where e.individual_id = p_individual and e.active), '[]'::jsonb),
    'income', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'label', i.label, 'amount', i.amount, 'frequency', i.frequency,
        'times_per_year', i.times_per_year, 'spread_months', i.spread_months, 'note', i.note) order by i.kind, i.label)
      from mirror.income_sources i where i.individual_id = p_individual and i.active), '[]'::jsonb),
    'noncash', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'category', n.category, 'label', n.label, 'amount', n.amount,
        'frequency', n.frequency, 'times_per_year', n.times_per_year, 'spread_months', n.spread_months, 'note', n.note) order by n.kind, n.label)
      from mirror.noncash_resources n where n.individual_id = p_individual and n.active), '[]'::jsonb),
    'tax_rate_pct', coalesce((select s.tax_rate_pct from mirror.daily_number_settings s where s.individual_id = p_individual), 0));
$$;

-- The result for a set of inputs (JSON in, JSON out): exactly the figures of daily-number.js.
create or replace function mirror.daily_number_calc(p jsonb) returns jsonb
language plpgsql immutable set search_path = mirror, public as $$
declare
  v_tax numeric := least(greatest(coalesce((p ->> 'tax_rate_pct')::numeric, 0), 0), 90) / 100;
  v_income numeric;
  v_noncash numeric;
  v_levels jsonb := '{}'::jsonb;
  lv text;
  v_cost numeric; v_cash numeric; v_others numeric; v_premium numeric; v_applied numeric; v_need numeric; v_lines int;
begin
  select coalesce(sum(mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int)), 0)
    into v_income from jsonb_array_elements(coalesce(p -> 'income', '[]')) x where coalesce((x ->> 'active')::boolean, true);
  select coalesce(sum(mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int)), 0)
    into v_noncash from jsonb_array_elements(coalesce(p -> 'noncash', '[]')) x where coalesce((x ->> 'active')::boolean, true);

  foreach lv in array array['current', 'survival', 'stability', 'aspirational'] loop
    with lines as (
      select x ->> 'category' cat, x ->> 'paid_by' paid_by, coalesce((x ->> 'poverty_premium')::boolean, false) premium,
             mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int) y
      from jsonb_array_elements(coalesce(p -> 'expenses', '[]')) x
      where coalesce((x ->> 'active')::boolean, true)
        and (x ->> 'level' = lv or (lv = 'aspirational' and x ->> 'level' = 'stability'))),
    nc as (
      select x ->> 'category' cat,
             sum(mirror.annual_of((x ->> 'amount')::numeric, x ->> 'frequency', (x ->> 'times_per_year')::numeric, (x ->> 'spread_months')::int)) y
      from jsonb_array_elements(coalesce(p -> 'noncash', '[]')) x where coalesce((x ->> 'active')::boolean, true) group by 1),
    cash_cat as (select cat, sum(y) y from lines where paid_by = 'self' group by 1)
    select count(*)::int, coalesce(sum(y), 0), coalesce(sum(y) filter (where paid_by = 'self'), 0), coalesce(sum(y) filter (where paid_by <> 'self'), 0),
           coalesce(sum(y) filter (where premium), 0),
           (select coalesce(sum(least(c.y, coalesce(n.y, 0))), 0) from cash_cat c left join nc n on n.cat = c.cat)
      into v_lines, v_cost, v_cash, v_others, v_premium, v_applied
      from lines;
    v_need := v_cash - v_applied;
    v_levels := v_levels || jsonb_build_object(lv, jsonb_build_object(
      'lines', v_lines, 'cost', mirror.per(v_cost), 'cash_expenses', mirror.per(v_cash), 'paid_by_others', mirror.per(v_others),
      'noncash_applied', mirror.per(v_applied), 'cash_needed', mirror.per(v_need), 'shortfall', mirror.per(greatest(0, v_need - v_income)),
      'gross_needed', mirror.per(v_need / (1 - v_tax)), 'poverty_premium', mirror.per(v_premium)));
  end loop;
  return jsonb_build_object('method', 1, 'tax_rate_pct', v_tax * 100, 'income', mirror.per(v_income), 'noncash', mirror.per(v_noncash), 'levels', v_levels);
end $$;

create or replace function mirror.daily_number(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select mirror.daily_number_calc(mirror.daily_number_inputs(p_individual));
$$;

-- ---------------------------------------------------------------- functions for pages (topic "financial", D-14)

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
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'label', g.label, 'target_amount', g.target_amount,
        'current_amount', g.current_amount, 'target_date', g.target_date) order by g.created_at) from mirror.financial_goals g where g.individual_id = v), '[]'::jsonb),
    'results', mirror.daily_number_calc(inp),
    'snapshots', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role,
        'current_daily', s.results #> '{levels,current,cost,daily}', 'stability_daily', s.results #> '{levels,stability,cost,daily}') order by s.taken_at desc)
      from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb));
end $$;

-- Add or change one record. p_kind: expense | income | noncash | goal | settings. p.id present = change that record.
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
begin
  perform mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  if p_kind in ('expense', 'income', 'noncash') then
    begin v_amount := round(replace(replace(coalesce(p ->> 'amount', ''), '$', ''), ',', '')::numeric, 2);
    exception when others then raise exception 'Enter an amount, for example 120 or 45.50.' using errcode = '22023'; end;
    if v_label is null then raise exception 'Give it a short name, for example "Rent".' using errcode = '22023'; end if;
    if v_freq = 'irregular' and v_times is null then raise exception 'How many times a year?' using errcode = '22023'; end if;
  end if;
  if p_kind = 'expense' then
    if v_id is null then
      insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, note)
      values (v, p ->> 'level', p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, coalesce(nullif(p ->> 'paid_by', ''), 'self'),
              coalesce((p ->> 'poverty_premium')::boolean, false), nullif(btrim(p ->> 'note'), ''));
    else
      update mirror.living_expenses set level = p ->> 'level', category = p ->> 'category', label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, paid_by = coalesce(nullif(p ->> 'paid_by', ''), 'self'),
        poverty_premium = coalesce((p ->> 'poverty_premium')::boolean, false), note = nullif(btrim(p ->> 'note'), ''), updated_at = now()
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'income' then
    if v_id is null then
      insert into mirror.income_sources (individual_id, kind, label, amount, frequency, times_per_year, spread_months, note)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''));
    else
      update mirror.income_sources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), updated_at = now() where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'noncash' then
    if v_id is null then
      insert into mirror.noncash_resources (individual_id, kind, category, label, amount, frequency, times_per_year, spread_months, note)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''));
    else
      update mirror.noncash_resources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), category = p ->> 'category', label = v_label, amount = v_amount,
        frequency = v_freq, times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), updated_at = now()
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'goal' then
    if v_label is null then raise exception 'Give the goal a name.' using errcode = '22023'; end if;
    if v_id is null then
      insert into mirror.financial_goals (individual_id, kind, label, target_amount, current_amount, target_date)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'savings'), v_label, nullif(p ->> 'target_amount', '')::numeric, coalesce(nullif(p ->> 'current_amount', '')::numeric, 0), nullif(p ->> 'target_date', '')::date);
    else
      update mirror.financial_goals set kind = coalesce(nullif(p ->> 'kind', ''), 'savings'), label = v_label, target_amount = nullif(p ->> 'target_amount', '')::numeric,
        current_amount = coalesce(nullif(p ->> 'current_amount', '')::numeric, 0), target_date = nullif(p ->> 'target_date', '')::date, updated_at = now()
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
  when check_violation then raise exception 'Something in that entry is not allowed (check the amount, how often, and the choices).' using errcode = '22023';
  when foreign_key_violation then raise exception 'Choose a category from the list.' using errcode = '22023';
  when not_null_violation then raise exception 'Something is missing: choose the level, the category and how often.' using errcode = '22023';
end $$;

-- Remove one line (the dated snapshots still show what it was).
create or replace function public.mirror_dn_delete(p_kind text, p_id uuid, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual);
begin
  perform mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  if p_kind = 'expense' then delete from mirror.living_expenses where id = p_id and individual_id = v;
  elsif p_kind = 'income' then delete from mirror.income_sources where id = p_id and individual_id = v;
  elsif p_kind = 'noncash' then delete from mirror.noncash_resources where id = p_id and individual_id = v;
  elsif p_kind = 'goal' then delete from mirror.financial_goals where id = p_id and individual_id = v;
  else raise exception 'Unknown record.' using errcode = '22023'; end if;
  if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return mirror.daily_number(v);
end $$;

-- Save today's Daily Number with its inputs and assumptions (prompt: "preserve its date and assumptions").
create or replace function public.mirror_dn_snapshot(p_note text default null, p_individual uuid default null) returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb; inp jsonb; v_id uuid;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number_snapshots', null);
  inp := mirror.daily_number_inputs(v);
  insert into mirror.daily_number_snapshots (individual_id, method_version, inputs, results, note, taken_by, taken_by_role)
  values (v, 1, inp, mirror.daily_number_calc(inp), nullif(btrim(p_note), ''), lower(auth.email()), g ->> 'role') returning id into v_id;
  return v_id;
end $$;

create or replace function public.mirror_dn_history(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb;
begin
  r := mirror.allowed(v, 'financial', 'view', null, 'daily_number_snapshots', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role, 'inputs', s.inputs, 'results', s.results)
    order by s.taken_at desc) from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- triggers, row security, grants

create trigger living_expenses_touch before update on mirror.living_expenses for each row execute function mirror.touch();
create trigger income_sources_touch before update on mirror.income_sources for each row execute function mirror.touch();
create trigger noncash_resources_touch before update on mirror.noncash_resources for each row execute function mirror.touch();
create trigger financial_goals_touch before update on mirror.financial_goals for each row execute function mirror.touch();

alter table mirror.expense_categories enable row level security;
alter table mirror.living_expenses enable row level security;
alter table mirror.income_sources enable row level security;
alter table mirror.noncash_resources enable row level security;
alter table mirror.financial_goals enable row level security;
alter table mirror.daily_number_settings enable row level security;
alter table mirror.daily_number_snapshots enable row level security;

revoke all on mirror.expense_categories, mirror.living_expenses, mirror.income_sources, mirror.noncash_resources, mirror.financial_goals,
  mirror.daily_number_settings, mirror.daily_number_snapshots from public, anon, authenticated;
grant all on mirror.expense_categories, mirror.living_expenses, mirror.income_sources, mirror.noncash_resources, mirror.financial_goals,
  mirror.daily_number_settings, mirror.daily_number_snapshots to service_role;

revoke all on function mirror.annual_of(numeric, text, numeric, int), mirror.per(numeric), mirror.daily_number_inputs(uuid), mirror.daily_number_calc(jsonb),
  mirror.daily_number(uuid), mirror.snapshots_never_change() from public, anon, authenticated;
grant execute on function mirror.annual_of(numeric, text, numeric, int), mirror.per(numeric), mirror.daily_number_inputs(uuid), mirror.daily_number_calc(jsonb),
  mirror.daily_number(uuid) to service_role;

revoke all on function public.mirror_dn_get(uuid), public.mirror_dn_save(text, jsonb, uuid), public.mirror_dn_delete(text, uuid, uuid),
  public.mirror_dn_snapshot(text, uuid), public.mirror_dn_history(uuid) from public, anon;
grant execute on function public.mirror_dn_get(uuid), public.mirror_dn_save(text, jsonb, uuid), public.mirror_dn_delete(text, uuid, uuid),
  public.mirror_dn_snapshot(text, uuid), public.mirror_dn_history(uuid) to authenticated, service_role;
