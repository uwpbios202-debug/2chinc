-- The Human Mirror, Phase 4 step 4 "the paper's model" (Stephen, 11/13/2026). No change to the arithmetic (method 4 stays).
--  1. Household: mirror.household_members (who lives with or helps the person). A cost can be paid by "someone in my household"
--     (paid_by 'household', optional household_member_id); money a household member gives is cash income linked to that member.
--     Both count exactly as before: 'household' is one more "paid for you" payer, family money is income (kind family_support).
--  2. Benefits and subsidies: mirror.benefit_records (program, status, applied / approved / renewal / appeal-by / end dates, and the
--     money line it pays: an income, help-that-isn't-cash or cost line). The money lives on the linked line only, never twice.
--  3. Income opportunities: mirror.income_opportunities (job, more hours, a raise, side work, a benefit to apply for, ...), with the
--     amount, before or after taxes, when it may start, and its status. Not counted in the Daily Number until it starts:
--     mirror_dn_save('opportunity_start') turns it into a real income line (take-home = amount x (1 - tax rate) when the amount is
--     before taxes and the income is taxed) in one step. The "How will I generate my Daily Number?" and "What if" pages calculate
--     in daily-number.js only and save nothing.
--  4. Fixed on the way: copying a list kept "could go down" but lost which kind (premium_kind); it now copies it, and the payer link.
-- Live bodies of 11/13 used for every replaced function (mirror_dn_save/delete/get/copy, daily_number_inputs, mirror_my_export).
-- Grants (CLAUDE.md, 10/30/2026 rule): the three new tables are for service_role only (pages reach them through the functions);
-- anon and authenticated get nothing. Row security on.

-- ---------------------------------------------------------------- tables

create table mirror.household_members (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  label text not null check (length(label) between 1 and 80),
  relationship text not null default 'other' check (relationship in ('partner', 'child', 'parent', 'sibling', 'other_family', 'friend', 'roommate', 'other')),
  lives_with boolean not null default true,
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index household_members_individual on mirror.household_members (individual_id);

alter table mirror.living_expenses drop constraint living_expenses_paid_by_check;
alter table mirror.living_expenses add constraint living_expenses_paid_by_check
  check (paid_by in ('self', 'subsidy', 'assistance', 'donated', 'household'));
alter table mirror.living_expenses add column household_member_id uuid references mirror.household_members(id) on delete set null;
alter table mirror.income_sources add column household_member_id uuid references mirror.household_members(id) on delete set null;

create table mirror.benefit_records (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  program text not null check (length(program) between 1 and 120),
  kind text not null default 'other' check (kind in ('food', 'cash', 'health', 'housing', 'childcare', 'energy', 'phone', 'other')),
  agency text check (agency is null or length(agency) <= 120),
  status text not null default 'active' check (status in ('considering', 'applied', 'active', 'denied', 'appealing', 'ended')),
  applied_on date,
  approved_on date,
  renewal_on date,          -- renewal or recertification due
  appeal_by date,           -- last day to appeal a denial or a cut
  ends_on date,
  income_source_id uuid references mirror.income_sources(id) on delete set null,
  noncash_id uuid references mirror.noncash_resources(id) on delete set null,
  expense_id uuid references mirror.living_expenses(id) on delete set null,
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(income_source_id, noncash_id, expense_id) <= 1)
);
create index benefit_records_individual on mirror.benefit_records (individual_id);

create table mirror.income_opportunities (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  kind text not null default 'job' check (kind in ('job', 'more_hours', 'raise', 'side_work', 'benefit', 'training', 'family', 'other')),
  label text not null check (length(label) between 1 and 120),
  amount numeric(12,2) not null check (amount >= 0 and amount <= 10000000),
  frequency text not null check (frequency in ('daily', 'weekly', 'biweekly', 'twice_month', 'monthly', 'quarterly', 'annual', 'irregular', 'one_time')),
  times_per_year numeric(8,2) check (times_per_year is null or times_per_year > 0),
  spread_months int check (spread_months is null or spread_months between 1 and 120),
  amount_is_gross boolean not null default true,      -- the amount is pay before taxes
  taxable boolean,                                    -- null = by kind (job, more hours, raise, side work are taxed)
  applies_to text[] check (applies_to is null or applies_to <@ array['current', 'survival', 'stability', 'aspirational']),
  expected_on date,
  status text not null default 'idea' check (status in ('idea', 'working_on', 'started', 'dropped')),
  next_step text check (next_step is null or length(next_step) <= 300),
  income_source_id uuid references mirror.income_sources(id) on delete set null,
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (frequency <> 'irregular' or times_per_year is not null)
);
create index income_opportunities_individual on mirror.income_opportunities (individual_id);

create trigger household_members_touch before update on mirror.household_members for each row execute function mirror.touch();
create trigger benefit_records_touch before update on mirror.benefit_records for each row execute function mirror.touch();
create trigger income_opportunities_touch before update on mirror.income_opportunities for each row execute function mirror.touch();

alter table mirror.household_members enable row level security;
alter table mirror.benefit_records enable row level security;
alter table mirror.income_opportunities enable row level security;
revoke all on mirror.household_members, mirror.benefit_records, mirror.income_opportunities from public, anon, authenticated;
grant all on mirror.household_members, mirror.benefit_records, mirror.income_opportunities to service_role;

-- ---------------------------------------------------------------- inputs: the payer link on costs and income

CREATE OR REPLACE FUNCTION mirror.daily_number_inputs(p_individual uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
  select jsonb_build_object(
    'as_of', mirror.today_local(),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'level', e.level, 'category', e.category, 'label', e.label, 'amount', e.amount,
        'frequency', e.frequency, 'times_per_year', e.times_per_year, 'spread_months', e.spread_months, 'paid_by', e.paid_by,
        'poverty_premium', e.poverty_premium, 'premium_kind', e.premium_kind, 'note', e.note, 'start_on', e.start_on, 'end_on', e.end_on,
        'household_member_id', e.household_member_id) order by e.level, e.category, e.label)
      from mirror.living_expenses e where e.individual_id = p_individual and e.active), '[]'::jsonb),
    'income', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'label', i.label, 'amount', i.amount, 'frequency', i.frequency,
        'times_per_year', i.times_per_year, 'spread_months', i.spread_months, 'note', i.note, 'start_on', i.start_on, 'end_on', i.end_on,
        'applies_to', i.applies_to, 'taxable', i.taxable, 'household_member_id', i.household_member_id) order by i.kind, i.label)
      from mirror.income_sources i where i.individual_id = p_individual and i.active), '[]'::jsonb),
    'noncash', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'category', n.category, 'label', n.label, 'amount', n.amount,
        'frequency', n.frequency, 'times_per_year', n.times_per_year, 'spread_months', n.spread_months, 'note', n.note, 'start_on', n.start_on, 'end_on', n.end_on,
        'applies_to', n.applies_to) order by n.kind, n.label)
      from mirror.noncash_resources n where n.individual_id = p_individual and n.active), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'label', g.label, 'level', g.level, 'target_amount', g.target_amount,
        'current_amount', g.current_amount, 'target_date', g.target_date) order by g.created_at)
      from mirror.financial_goals g where g.individual_id = p_individual), '[]'::jsonb),
    'tax_rate_pct', coalesce((select s.tax_rate_pct from mirror.daily_number_settings s where s.individual_id = p_individual), 0));
$function$;

-- The plan records (household, benefits, opportunities) for one person: shown on the pages and in the download, not in the calculation.
create or replace function mirror.dn_plan(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'label', m.label, 'relationship', m.relationship, 'lives_with', m.lives_with,
        'note', m.note) order by m.created_at) from mirror.household_members m where m.individual_id = p_individual), '[]'::jsonb),
    'benefits', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'program', b.program, 'kind', b.kind, 'agency', b.agency, 'status', b.status,
        'applied_on', b.applied_on, 'approved_on', b.approved_on, 'renewal_on', b.renewal_on, 'appeal_by', b.appeal_by, 'ends_on', b.ends_on,
        'income_source_id', b.income_source_id, 'noncash_id', b.noncash_id, 'expense_id', b.expense_id, 'note', b.note) order by b.program)
      from mirror.benefit_records b where b.individual_id = p_individual), '[]'::jsonb),
    'opportunities', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'label', o.label, 'amount', o.amount, 'frequency', o.frequency,
        'times_per_year', o.times_per_year, 'spread_months', o.spread_months, 'amount_is_gross', o.amount_is_gross, 'taxable', o.taxable,
        'applies_to', o.applies_to, 'expected_on', o.expected_on, 'status', o.status, 'next_step', o.next_step,
        'income_source_id', o.income_source_id, 'note', o.note) order by o.created_at)
      from mirror.income_opportunities o where o.individual_id = p_individual), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------- page functions (live bodies + the new records)

CREATE OR REPLACE FUNCTION public.mirror_dn_get(p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
    'plan', mirror.dn_plan(v),
    'snapshots', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role,
        'current_daily', s.results #> '{levels,current,cost,daily}', 'stability_daily', s.results #> '{levels,stability,cost,daily}') order by s.taken_at desc)
      from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_dn_save(p_kind text, p jsonb, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
  v_premium_kind text := nullif(p ->> 'premium_kind', '');
  v_premium boolean := coalesce((p ->> 'poverty_premium')::boolean, false) or v_premium_kind is not null;
  v_member uuid;
  v_paid text := coalesce(nullif(p ->> 'paid_by', ''), 'self');
  v_d1 date; v_d2 date; v_d3 date; v_d4 date; v_d5 date;
  v_link_inc uuid; v_link_nc uuid; v_link_ex uuid;
  o mirror.income_opportunities;
  v_tax numeric;
  v_inc uuid;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  begin v_start := nullif(p ->> 'start_on', '')::date; v_end := nullif(p ->> 'end_on', '')::date;
  exception when others then raise exception 'One of the dates is not a real date.' using errcode = '22023'; end;
  begin v_member := nullif(p ->> 'household_member_id', '')::uuid;
  exception when others then raise exception 'Choose someone from your household list.' using errcode = '22023'; end;
  if v_member is not null and not exists (select 1 from mirror.household_members m where m.id = v_member and m.individual_id = v) then
    raise exception 'Choose someone from your household list.' using errcode = '22023';
  end if;
  if p_kind in ('expense', 'income', 'noncash', 'opportunity') then
    begin v_amount := round(replace(replace(coalesce(p ->> 'amount', ''), '$', ''), ',', '')::numeric, 2);
    exception when others then raise exception 'Enter an amount, for example 120 or 45.50.' using errcode = '22023'; end;
    if v_label is null then raise exception 'Give it a short name, for example "Rent".' using errcode = '22023'; end if;
    if v_freq = 'irregular' and v_times is null then raise exception 'How many times a year?' using errcode = '22023'; end if;
    if v_start is not null and v_end is not null and v_end < v_start then raise exception 'The end date is before the start date.' using errcode = '22023'; end if;
  end if;
  if p_kind = 'benefit' then
    begin
      v_d1 := nullif(p ->> 'applied_on', '')::date; v_d2 := nullif(p ->> 'approved_on', '')::date; v_d3 := nullif(p ->> 'renewal_on', '')::date;
      v_d4 := nullif(p ->> 'appeal_by', '')::date; v_d5 := nullif(p ->> 'ends_on', '')::date;
      v_link_inc := nullif(p ->> 'income_source_id', '')::uuid; v_link_nc := nullif(p ->> 'noncash_id', '')::uuid; v_link_ex := nullif(p ->> 'expense_id', '')::uuid;
    exception when others then raise exception 'One of the dates is not a real date.' using errcode = '22023'; end;
    if nullif(btrim(coalesce(p ->> 'program', '')), '') is null then raise exception 'Name the program, for example "FoodShare".' using errcode = '22023'; end if;
    if (v_link_inc is not null and not exists (select 1 from mirror.income_sources where id = v_link_inc and individual_id = v))
       or (v_link_nc is not null and not exists (select 1 from mirror.noncash_resources where id = v_link_nc and individual_id = v))
       or (v_link_ex is not null and not exists (select 1 from mirror.living_expenses where id = v_link_ex and individual_id = v)) then
      raise exception 'Choose the amount from your own lists.' using errcode = '22023';
    end if;
  end if;
  perform mirror.dn_auto_snapshot(v, g ->> 'role');
  if p_kind = 'expense' then
    if v_paid <> 'household' then v_member := null; end if;
    if v_id is null then
      insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, premium_kind, note, start_on, end_on, household_member_id)
      values (v, p ->> 'level', p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, v_paid,
              v_premium, v_premium_kind, nullif(btrim(p ->> 'note'), ''), v_start, v_end, v_member);
    else
      update mirror.living_expenses set level = p ->> 'level', category = p ->> 'category', label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, paid_by = v_paid,
        poverty_premium = v_premium, premium_kind = v_premium_kind, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end,
        household_member_id = v_member
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'income' then
    if v_id is null then
      insert into mirror.income_sources (individual_id, kind, label, amount, frequency, times_per_year, spread_months, note, start_on, end_on, applies_to, taxable, household_member_id)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'other'), v_label, v_amount, v_freq, v_times, v_spread, nullif(btrim(p ->> 'note'), ''), v_start, v_end, v_applies, v_taxable, v_member);
    else
      update mirror.income_sources set kind = coalesce(nullif(p ->> 'kind', ''), 'other'), label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end,
        applies_to = v_applies, taxable = v_taxable, household_member_id = v_member
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
  elsif p_kind = 'member' then
    if v_label is null then raise exception 'Give a first name or how they are related, for example "My sister".' using errcode = '22023'; end if;
    if v_id is null then
      insert into mirror.household_members (individual_id, label, relationship, lives_with, note)
      values (v, v_label, coalesce(nullif(p ->> 'relationship', ''), 'other'), coalesce((p ->> 'lives_with')::boolean, true), nullif(btrim(p ->> 'note'), ''));
    else
      update mirror.household_members set label = v_label, relationship = coalesce(nullif(p ->> 'relationship', ''), 'other'),
        lives_with = coalesce((p ->> 'lives_with')::boolean, true), note = nullif(btrim(p ->> 'note'), '')
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'benefit' then
    if v_id is null then
      insert into mirror.benefit_records (individual_id, program, kind, agency, status, applied_on, approved_on, renewal_on, appeal_by, ends_on,
        income_source_id, noncash_id, expense_id, note)
      values (v, btrim(p ->> 'program'), coalesce(nullif(p ->> 'kind', ''), 'other'), nullif(btrim(p ->> 'agency'), ''), coalesce(nullif(p ->> 'status', ''), 'active'),
        v_d1, v_d2, v_d3, v_d4, v_d5, v_link_inc, v_link_nc, v_link_ex, nullif(btrim(p ->> 'note'), ''));
    else
      update mirror.benefit_records set program = btrim(p ->> 'program'), kind = coalesce(nullif(p ->> 'kind', ''), 'other'), agency = nullif(btrim(p ->> 'agency'), ''),
        status = coalesce(nullif(p ->> 'status', ''), 'active'), applied_on = v_d1, approved_on = v_d2, renewal_on = v_d3, appeal_by = v_d4, ends_on = v_d5,
        income_source_id = v_link_inc, noncash_id = v_link_nc, expense_id = v_link_ex, note = nullif(btrim(p ->> 'note'), '')
      where id = v_id and individual_id = v;
      if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'opportunity' then
    begin v_d1 := nullif(p ->> 'expected_on', '')::date;
    exception when others then raise exception 'One of the dates is not a real date.' using errcode = '22023'; end;
    if coalesce(p ->> 'status', '') = 'started' then
      raise exception 'Use "It started" to make it income.' using errcode = '22023';
    end if;
    if v_id is null then
      insert into mirror.income_opportunities (individual_id, kind, label, amount, frequency, times_per_year, spread_months, amount_is_gross, taxable, applies_to,
        expected_on, status, next_step, note)
      values (v, coalesce(nullif(p ->> 'kind', ''), 'job'), v_label, v_amount, v_freq, v_times, v_spread, coalesce((p ->> 'amount_is_gross')::boolean, true), v_taxable, v_applies,
        v_d1, coalesce(nullif(p ->> 'status', ''), 'idea'), nullif(btrim(p ->> 'next_step'), ''), nullif(btrim(p ->> 'note'), ''));
    else
      update mirror.income_opportunities set kind = coalesce(nullif(p ->> 'kind', ''), 'job'), label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, amount_is_gross = coalesce((p ->> 'amount_is_gross')::boolean, true), taxable = v_taxable,
        applies_to = v_applies, expected_on = v_d1, status = coalesce(nullif(p ->> 'status', ''), 'idea'), next_step = nullif(btrim(p ->> 'next_step'), ''),
        note = nullif(btrim(p ->> 'note'), '')
      where id = v_id and individual_id = v and status <> 'started';
      if not found then raise exception 'Not found, or it has already started (change it on Income and support).' using errcode = 'P0002'; end if;
    end if;
  elsif p_kind = 'opportunity_start' then
    -- One step: the opportunity becomes a real cash income line from its start date, and is marked started.
    select * into o from mirror.income_opportunities where id = v_id and individual_id = v for update;
    if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    if o.status = 'started' then raise exception 'It has already started.' using errcode = '22023'; end if;
    v_tax := coalesce((select tax_rate_pct from mirror.daily_number_settings where individual_id = v), 0);
    v_taxable := coalesce(o.taxable, o.kind in ('job', 'more_hours', 'raise', 'side_work'));
    insert into mirror.income_sources (individual_id, kind, label, amount, frequency, times_per_year, spread_months, note, start_on, applies_to, taxable)
    values (v, case o.kind when 'job' then 'wages' when 'more_hours' then 'wages' when 'raise' then 'wages' when 'side_work' then 'self_employment'
                           when 'benefit' then 'cash_benefit' when 'family' then 'family_support' else 'other' end,
      o.label,
      case when o.amount_is_gross and v_taxable then round(o.amount * (1 - v_tax / 100), 2) else o.amount end,
      o.frequency, o.times_per_year, o.spread_months,
      'From my plan' || case when o.amount_is_gross and v_taxable then format(' ($%s before taxes, %s%% tax)', to_char(o.amount, 'FM999,999,990.00'), trim_scale(v_tax)) else '' end,
      coalesce(v_start, mirror.today_local()), o.applies_to, v_taxable)
    returning id into v_inc;
    update mirror.income_opportunities set status = 'started', income_source_id = v_inc where id = o.id;
  else
    raise exception 'Unknown record.' using errcode = '22023';
  end if;
  return mirror.daily_number(v);
exception
  when check_violation then raise exception 'Something in that entry is not allowed (check the amount, how often, the dates and the choices).' using errcode = '22023';
  when foreign_key_violation then raise exception 'Choose a category from the list.' using errcode = '22023';
  when not_null_violation then raise exception 'Something is missing: choose the level, the category and how often.' using errcode = '22023';
  when invalid_datetime_format or datetime_field_overflow then raise exception 'One of the dates is not a real date.' using errcode = '22023';
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_dn_delete(p_kind text, p_id uuid, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid := mirror.target_individual(p_individual); g jsonb;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number', p_kind);
  perform mirror.dn_auto_snapshot(v, g ->> 'role');
  if p_kind = 'expense' then delete from mirror.living_expenses where id = p_id and individual_id = v;
  elsif p_kind = 'income' then delete from mirror.income_sources where id = p_id and individual_id = v;
  elsif p_kind = 'noncash' then delete from mirror.noncash_resources where id = p_id and individual_id = v;
  elsif p_kind = 'goal' then delete from mirror.financial_goals where id = p_id and individual_id = v;
  elsif p_kind = 'member' then delete from mirror.household_members where id = p_id and individual_id = v;
  elsif p_kind = 'benefit' then delete from mirror.benefit_records where id = p_id and individual_id = v;
  elsif p_kind = 'opportunity' then delete from mirror.income_opportunities where id = p_id and individual_id = v;
  else raise exception 'Unknown record.' using errcode = '22023'; end if;
  if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return mirror.daily_number(v);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_dn_copy(p_from text, p_to text, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid := mirror.target_individual(p_individual); n int; g jsonb;
begin
  g := mirror.require(v, 'financial', 'edit', null, 'daily_number', 'copy');
  if p_from not in ('current', 'survival', 'stability', 'aspirational') or p_to not in ('current', 'survival', 'stability', 'aspirational') or p_from = p_to then
    raise exception 'Choose two different lists.' using errcode = '22023';
  end if;
  perform mirror.dn_auto_snapshot(v, g ->> 'role');
  insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, premium_kind, note, start_on, end_on, household_member_id)
  select individual_id, p_to, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, premium_kind, note, start_on, end_on, household_member_id
  from mirror.living_expenses where individual_id = v and level = p_from and active;
  get diagnostics n = row_count;
  return jsonb_build_object('copied', n, 'results', mirror.daily_number(v));
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_my_export()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
    'answers', coalesce((select jsonb_agg(jsonb_build_object('set', s.title, 'set_key', s.key, 'question', qv.prompt, 'question_key', q.key,
        'question_version', x.question_version,
        'answer', x.value, 'state', x.state, 'note', x.note, 'by', x.answered_by_role, 'at', x.answered_at, 'current', x.superseded_at is null)
        order by s.kind, s.sort, q.sort, x.answered_at)
      from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
      join mirror.question_sets s on s.id = a.set_id join mirror.reflection_questions q on q.id = x.question_id
      join mirror.question_versions qv on qv.question_id = x.question_id and qv.version = x.question_version
      where a.individual_id = v), '[]'::jsonb),
    'daily_number', jsonb_build_object(
      'inputs', mirror.daily_number_inputs(v),
      'household_size', (select household_size from mirror.daily_number_settings where individual_id = v),
      'results', mirror.daily_number(v),
      'plan', mirror.dn_plan(v),
      'saved', coalesce((select jsonb_agg(jsonb_build_object('taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role, 'inputs', s.inputs, 'results', s.results)
          order by s.taken_at) from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb)),
    'who_looked', public.mirror_who_looked());
  perform mirror.audit(v, null, 'self', 'export', 'general', 'individuals', null);
  return r;
end $function$;

-- ---------------------------------------------------------------- grants
revoke all on function mirror.dn_plan(uuid) from public, anon, authenticated;
grant execute on function mirror.dn_plan(uuid) to service_role;
