-- The Human Mirror, Daily Number step 3 "make it usable" (Stephen, 11/13/2026).
-- premium_kind: which "cost of being poor" a line is (the paper's section 7), so the gap page can show a cheaper way for each.
-- Choosing a kind also marks the line as a cost that could go down. mirror_dn_save and mirror.daily_number_inputs are the step-2
-- versions (migration 20261119250000) with premium_kind added; nothing else in them changed.

alter table mirror.living_expenses add column premium_kind text check (premium_kind is null or premium_kind in ('small_quantities', 'convenience_store', 'laundromat', 'prepaid_phone', 'long_commute', 'per_ride_fares', 'late_fees', 'overdraft', 'check_cashing', 'payday_loan', 'rent_to_own', 'no_reserve', 'other'));

create or replace function mirror.daily_number_inputs(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object(
    'as_of', mirror.today_local(),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'level', e.level, 'category', e.category, 'label', e.label, 'amount', e.amount,
        'frequency', e.frequency, 'times_per_year', e.times_per_year, 'spread_months', e.spread_months, 'paid_by', e.paid_by,
        'poverty_premium', e.poverty_premium, 'premium_kind', e.premium_kind, 'note', e.note, 'start_on', e.start_on, 'end_on', e.end_on) order by e.level, e.category, e.label)
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
  v_premium_kind text := nullif(p ->> 'premium_kind', '');
  v_premium boolean := coalesce((p ->> 'poverty_premium')::boolean, false) or v_premium_kind is not null;
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
      insert into mirror.living_expenses (individual_id, level, category, label, amount, frequency, times_per_year, spread_months, paid_by, poverty_premium, premium_kind, note, start_on, end_on)
      values (v, p ->> 'level', p ->> 'category', v_label, v_amount, v_freq, v_times, v_spread, coalesce(nullif(p ->> 'paid_by', ''), 'self'),
              v_premium, v_premium_kind, nullif(btrim(p ->> 'note'), ''), v_start, v_end);
    else
      update mirror.living_expenses set level = p ->> 'level', category = p ->> 'category', label = v_label, amount = v_amount, frequency = v_freq,
        times_per_year = v_times, spread_months = v_spread, paid_by = coalesce(nullif(p ->> 'paid_by', ''), 'self'),
        poverty_premium = v_premium, premium_kind = v_premium_kind, note = nullif(btrim(p ->> 'note'), ''), start_on = v_start, end_on = v_end
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
