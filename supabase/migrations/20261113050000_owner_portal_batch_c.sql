-- Owner portal fixes, batch C (Stephen, 10/13/2026): money and the goodwill credit.
--   1. owner_goodwill_mine(): the owner sees whether the goodwill credit applies to each unit and why, what has been credited, and
--      when the next run is. READ ONLY: it never posts anything. It mirrors the rule in condo_goodwill_credits() (20261112030000);
--      if that rule changes, change condo_goodwill_status() to match.
--   2. owner_report_year(): a unit sold during the year stays in that year's summary for an owner who still owns another unit.
-- Nothing in the ledger is changed.

create or replace function condo_goodwill_status(p_account uuid, p_day date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_months int := condo_setting('dues_goodwill_months', '6')::int;
  v_try int := condo_setting('dues_goodwill_trying_days', '60')::int;
  v_eff date := condo_setting('dues_goodwill_effective', '2026-10-10')::date;
  v_unit uuid; v_step text; v_bal numeric; v_oldest date; e record; i int; g text; v_sum numeric;
  d_open numeric[] := '{}'; d_dt date[] := '{}'; f_open numeric[] := '{}'; f_dt date[] := '{}'; f_gl text[] := '{}';
  credit numeric := 0; m numeric; t numeric; v_fee numeric := 0; v_int numeric := 0; v_paid boolean;
begin
  select unit_id into v_unit from condo_ledger_accounts where id = p_account;
  v_bal := condo_account_balance(p_account, p_day);
  if v_bal <= 0.004 then return jsonb_build_object('state', 'paid_up'); end if;
  select step into v_step from condo_collection_steps where unit_id = v_unit order by step_date desc, id desc limit 1;
  if v_step in ('attorney', 'lien', 'foreclosure', 'judgment', 'written_off') then return jsonb_build_object('state', 'collections'); end if;
  v_paid := exists (select 1 from condo_ledger_entries where account_id = p_account and kind = 'payment' and amount < 0 and entry_date > p_day - v_try and entry_date <= p_day);
  for e in select * from condo_ledger_entries where account_id = p_account and entry_date <= p_day order by entry_date, id loop
    if e.amount > 0 then
      t := least(credit, e.amount); credit := credit - t;
      if e.gl_account in ('Late Fee Income', 'Interest Income') then f_open := f_open || (e.amount - t); f_dt := f_dt || e.entry_date; f_gl := f_gl || e.gl_account;
      else d_open := d_open || (e.amount - t); d_dt := d_dt || e.entry_date; end if;
    else
      m := -e.amount;
      if e.kind = 'credit' and e.gl_account in ('Late Fee Income', 'Interest Income') then
        for i in 1 .. coalesce(array_length(f_open, 1), 0) loop t := least(f_open[i], m); f_open[i] := f_open[i] - t; m := m - t; end loop;
        for i in 1 .. coalesce(array_length(d_open, 1), 0) loop t := least(d_open[i], m); d_open[i] := d_open[i] - t; m := m - t; end loop;
      else
        for i in 1 .. coalesce(array_length(d_open, 1), 0) loop t := least(d_open[i], m); d_open[i] := d_open[i] - t; m := m - t; end loop;
        for i in 1 .. coalesce(array_length(f_open, 1), 0) loop t := least(f_open[i], m); f_open[i] := f_open[i] - t; m := m - t; end loop;
      end if;
      credit := credit + m;
    end if;
  end loop;
  for i in 1 .. coalesce(array_length(d_open, 1), 0) loop
    if d_open[i] > 0.004 and (v_oldest is null or d_dt[i] < v_oldest) then v_oldest := d_dt[i]; end if;
  end loop;
  for i in 1 .. coalesce(array_length(f_open, 1), 0) loop
    if f_open[i] > 0.004 and f_dt[i] >= v_eff then
      if f_gl[i] = 'Interest Income' then v_int := v_int + f_open[i]; else v_fee := v_fee + f_open[i]; end if;
    end if;
  end loop;
  if v_oldest is not null and v_oldest < (p_day - make_interval(months => v_months))::date then
    return jsonb_build_object('state', 'too_old', 'oldest_unpaid', v_oldest);
  end if;
  if not (v_step = 'payment_plan' or v_paid) then
    return jsonb_build_object('state', 'not_trying', 'oldest_unpaid', v_oldest, 'fees', round(v_fee, 2), 'interest', round(v_int, 2));
  end if;
  return jsonb_build_object('state', 'eligible', 'oldest_unpaid', v_oldest, 'fees', round(v_fee, 2), 'interest', round(v_int, 2),
                            'window_ends', case when v_oldest is null then null else (v_oldest + make_interval(months => v_months))::date end);
end;
$$;
revoke all on function condo_goodwill_status(uuid, date) from public, anon, authenticated;

create or replace function owner_goodwill_mine()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_today date := (now() at time zone 'America/Chicago')::date;
  v_dom int := condo_setting('dues_late_pct_day', '11')::int + 1;
  v_next date;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  v_next := case when extract(day from v_today) <= v_dom then date_trunc('month', v_today)::date + (v_dom - 1)
                 else (date_trunc('month', v_today) + interval '1 month')::date + (v_dom - 1) end;
  return jsonb_build_object(
    'enabled', condo_setting('dues_goodwill', 'on') = 'on',
    'months', condo_setting('dues_goodwill_months', '6')::int,
    'trying_days', condo_setting('dues_goodwill_trying_days', '60')::int,
    'effective', condo_setting('dues_goodwill_effective', '2026-10-10'),
    'next_run', v_next,
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'unit', u.unit_number,
        'status', condo_goodwill_status(a.id, v_today),
        'credits', coalesce((select jsonb_agg(jsonb_build_object('date', x.entry_date, 'description', x.description, 'amount', -x.amount) order by x.entry_date desc, x.id desc)
                             from condo_ledger_entries x where x.account_id = a.id and x.entered_by = 'goodwill credit' and x.amount < 0), '[]'::jsonb),
        'credited_total', coalesce((select -sum(x.amount) from condo_ledger_entries x where x.account_id = a.id and x.entered_by = 'goodwill credit' and x.amount < 0), 0))
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int)
      from condo_ownerships s join condo_units u on u.id = s.unit_id
      join condo_ledger_accounts a on a.ownership_id = s.id and a.billing_account and not a.excluded
      where s.owner_id = v_owner and s.is_current), '[]'::jsonb));
end;
$$;
revoke all on function owner_goodwill_mine() from public, anon;
grant execute on function owner_goodwill_mine() to authenticated;

-- ---------------------------------------------------------------------------
-- Year-end summary: include a unit sold during the year (for an owner who still owns another unit).
do $do$
declare v text := pg_get_functiondef('owner_report_year(integer)'::regprocedure);
  v_old text := $o$where s.owner_id = v_owner and s.is_current),$o$;
  v_new text := $n$where s.owner_id = v_owner and (s.is_current or s.end_date >= y0)),$n$;
begin
  if position(v_old in v) = 0 then raise exception 'owner_report_year changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;
