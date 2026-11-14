-- Owner goodwill credit (Stephen, 10/12/2026): the unwritten rule, now written.
--
-- An owner who is bringing the account current, or is working to within about 6 months, is not penalized with late fees and
-- interest. Each month, the day after interest posts (dues_late_pct_day + 1, the 13th), every eligible account is credited
-- for the late fees and interest that are still UNPAID. The dues themselves are always owed in full.
--
-- Eligible (all of these):
--   * a current owner's billing account that owes something;
--   * the oldest unpaid dues are no more than dues_goodwill_months (6) months old;
--   * trying: a payment in the last dues_goodwill_trying_days (60) days, or the latest collections step is a payment plan;
--   * not in formal collection: the latest collections step is not attorney, lien, foreclosure, judgment or written_off.
-- Payments go to dues first (oldest first), then to late fees and interest (same rule as rent). Credits are separate ledger
-- lines on Late Fee Income / Interest Income; nothing is deleted or edited. Fees posted before dues_goodwill_effective are
-- left exactly as they are (the past stays as it was); the 10/12/2026 credit on Unit 7 was posted by hand.
-- To undo one month's credit, reverse the entry in the staff ledger.

insert into portal_settings (key, value) values
  ('dues_goodwill', 'on'),
  ('dues_goodwill_months', '6'),
  ('dues_goodwill_trying_days', '60'),
  ('dues_goodwill_effective', '2026-10-10')
on conflict (key) do nothing;

create or replace function condo_goodwill_credits(p_day date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_on text := condo_setting('dues_goodwill', 'on');
  v_months int := condo_setting('dues_goodwill_months', '6')::int;
  v_try int := condo_setting('dues_goodwill_trying_days', '60')::int;
  v_eff date := condo_setting('dues_goodwill_effective', '2026-10-10')::date;
  v_day int := condo_setting('dues_late_pct_day', '11')::int + 1;
  a record; e record; v_step text; v_oldest date; n int := 0; v_total numeric := 0;
  d_open numeric[]; d_dt date[]; f_open numeric[]; f_dt date[]; f_gl text[];
  credit numeric; m numeric; t numeric; i int; g text; v_sum numeric; v_cnt int; v_min date; v_max date;
begin
  if v_on <> 'on' or p_day < v_eff or extract(day from p_day) <> v_day then
    return jsonb_build_object('day', p_day, 'credit_entries', 0);
  end if;
  for a in select ca.id, ca.unit_id from condo_ledger_accounts ca
           join condo_ownerships s on s.id = ca.ownership_id and s.is_current
           where ca.billing_account and not ca.excluded and condo_account_balance(ca.id, p_day) > 0
  loop
    select step into v_step from condo_collection_steps where unit_id = a.unit_id order by step_date desc, id desc limit 1;
    continue when v_step in ('attorney', 'lien', 'foreclosure', 'judgment', 'written_off');
    continue when not (v_step = 'payment_plan' or exists (select 1 from condo_ledger_entries where account_id = a.id and kind = 'payment'
                       and amount < 0 and entry_date > p_day - v_try and entry_date <= p_day));
    -- Waterfall, oldest first: charges absorb any prepaid credit; payments and other credits retire dues first, then fees
    -- (a credit on Late Fee / Interest Income retires fees first).
    d_open := '{}'; d_dt := '{}'; f_open := '{}'; f_dt := '{}'; f_gl := '{}'; credit := 0;
    for e in select * from condo_ledger_entries where account_id = a.id and entry_date <= p_day order by entry_date, id loop
      if e.amount > 0 then
        t := least(credit, e.amount); credit := credit - t;
        if e.gl_account in ('Late Fee Income', 'Interest Income') then
          f_open := f_open || (e.amount - t); f_dt := f_dt || e.entry_date; f_gl := f_gl || e.gl_account;
        else
          d_open := d_open || (e.amount - t); d_dt := d_dt || e.entry_date;
        end if;
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
    v_oldest := null;
    for i in 1 .. coalesce(array_length(d_open, 1), 0) loop
      if d_open[i] > 0.004 and (v_oldest is null or d_dt[i] < v_oldest) then v_oldest := d_dt[i]; end if;
    end loop;
    -- Dues older than the window: no credit (the owner is not bringing the account current).
    continue when v_oldest is not null and v_oldest < (p_day - make_interval(months => v_months))::date;
    foreach g in array array['Late Fee Income', 'Interest Income'] loop
      v_sum := 0; v_cnt := 0; v_min := null; v_max := null;
      for i in 1 .. coalesce(array_length(f_open, 1), 0) loop
        if f_gl[i] = g and f_open[i] > 0.004 and f_dt[i] >= v_eff then
          v_sum := v_sum + f_open[i]; v_cnt := v_cnt + 1; v_min := least(coalesce(v_min, f_dt[i]), f_dt[i]); v_max := greatest(coalesce(v_max, f_dt[i]), f_dt[i]);
        end if;
      end loop;
      continue when v_sum <= 0;
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
      values (a.id, g, p_day, 'credit', 'Credit',
              'Credit to waive ' || v_cnt || case when g = 'Interest Income' then ' unpaid interest charge' else ' unpaid late fee' end || case when v_cnt > 1 then 's' else '' end
                || ' (' || to_char(v_min, 'FMMM/FMDD/YYYY') || ' to ' || to_char(v_max, 'FMMM/FMDD/YYYY') || ')',
              -round(v_sum, 2), 'billing', 'goodwill credit',
              'Owner goodwill rule: an owner bringing the account current within ' || v_months || ' months is not charged late fees or interest. Dues remain owed in full.');
      n := n + 1; v_total := v_total + round(v_sum, 2);
    end loop;
  end loop;
  return jsonb_build_object('day', p_day, 'credit_entries', n, 'total_credited', v_total);
end;
$$;
revoke all on function condo_goodwill_credits(date) from public, anon, authenticated;

-- Owner-occupied units (1, 7, 13) have no guest approval: the owner has whoever, whenever, for as long as they like.
create or replace function guest_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and coalesce(cu.occupancy, '') <> 'owner';
$$;
revoke all on function guest_my_units() from public, anon;
grant execute on function guest_my_units() to authenticated;
