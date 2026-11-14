-- Delete fee button for staff, tenants and owners (Stephen, 11/3/2026: "I need a delete button so I can delete fees").
-- Removes an unpaid, uncredited fee line posted on or after 10/10/2026 (older history is never touched). The original line is
-- kept in fee_deletions with who and why, and the nightly late-fee and interest jobs skip that fee for that month so it does not
-- come back. Rent, dues and the security deposit are never fees. A fee tied to a dispute, violation or lien cannot be deleted
-- (credit it instead).
create table if not exists fee_deletions (
  id bigint generated always as identity primary key,
  lease_id uuid references leases(id),
  condo_account_id uuid references condo_ledger_accounts(id),
  entry_id bigint not null,
  gl_account text not null,
  month date not null,
  amount numeric not null,
  entry jsonb not null,
  reason text not null,
  deleted_by text,
  deleted_at timestamptz not null default now(),
  check ((lease_id is null) <> (condo_account_id is null))
);
create index if not exists fee_deletions_lease on fee_deletions (lease_id, month);
create index if not exists fee_deletions_condo on fee_deletions (condo_account_id, month);
alter table fee_deletions enable row level security;
grant all on fee_deletions to service_role;

create or replace function lease_staff_delete_fee(p_entry bigint, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare e lease_ledger_entries; v_open numeric;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into e from lease_ledger_entries where id = p_entry;
  if e.id is null then raise exception 'Fee not found'; end if;
  perform 1 from leases where id = e.lease_id for update;
  if e.kind <> 'charge' or e.gl_account in ('Rent Income', 'Rent Charge', 'Security Deposit Liability', 'Pet Rent Income') then raise exception 'Only a fee can be deleted'; end if;
  if e.entry_date < date '2026-10-10' then raise exception 'Fees posted before 10/10/2026 are history and stay as they are'; end if;
  select (x->>'open')::numeric into v_open from jsonb_array_elements(lease_fee_open(e.lease_id)) x where (x->>'id')::bigint = e.id;
  if v_open is distinct from e.amount then raise exception 'This fee is partly paid or credited; use Credit fee instead'; end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the fee is deleted'; end if;
  insert into fee_deletions (lease_id, entry_id, gl_account, month, amount, entry, reason, deleted_by)
  values (e.lease_id, e.id, e.gl_account, date_trunc('month', e.entry_date)::date, e.amount, to_jsonb(e), trim(p_reason), auth.email());
  begin
    delete from lease_ledger_entries where id = e.id;
  exception when foreign_key_violation then
    raise exception 'This fee is linked to a dispute, violation or work record; use Credit fee instead';
  end;
  return jsonb_build_object('deleted', e.id, 'amount', e.amount);
end $$;
revoke all on function lease_staff_delete_fee(bigint, text) from public, anon;
grant execute on function lease_staff_delete_fee(bigint, text) to authenticated, service_role;

create or replace function condo_staff_delete_fee(p_entry bigint, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare e condo_ledger_entries; v_unit text; v_open numeric;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into e from condo_ledger_entries where id = p_entry;
  if e.id is null then raise exception 'Fee not found'; end if;
  perform 1 from condo_ledger_accounts where id = e.account_id for update;
  if e.amount <= 0 or e.kind not in ('charge', 'late_fee') or e.gl_account = 'Association Fee Income' then raise exception 'Only a fee can be deleted'; end if;
  if e.entry_date < date '2026-10-10' then raise exception 'Fees posted before 10/10/2026 are history and stay as they are'; end if;
  select u.unit_number into v_unit from condo_ledger_accounts a join condo_units u on u.id = a.unit_id where a.id = e.account_id;
  select (x->>'open')::numeric into v_open from jsonb_array_elements(condo_fee_open(v_unit)) x where (x->>'id')::bigint = e.id;
  if v_open is distinct from e.amount then raise exception 'This fee is partly paid or credited; use Credit fee instead'; end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the fee is deleted'; end if;
  insert into fee_deletions (condo_account_id, entry_id, gl_account, month, amount, entry, reason, deleted_by)
  values (e.account_id, e.id, e.gl_account, date_trunc('month', e.entry_date)::date, e.amount, to_jsonb(e), trim(p_reason), auth.email());
  begin
    delete from condo_ledger_entries where id = e.id;
  exception when foreign_key_violation then
    raise exception 'This fee is linked to a dispute, violation, assessment or lien; use Credit fee instead';
  end;
  return jsonb_build_object('deleted', e.id, 'amount', e.amount);
end $$;
revoke all on function condo_staff_delete_fee(bigint, text) from public, anon;
grant execute on function condo_staff_delete_fee(bigint, text) to authenticated, service_role;

-- The nightly jobs: same bodies as live, plus "skip if staff deleted this month's fee".
CREATE OR REPLACE FUNCTION public.rent_late_fees(p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  u record; v_month date := date_trunc('month', p_day)::date; v_fee numeric; v_posted jsonb := '[]'::jsonb;
begin
  if extract(day from p_day) < 2 then return jsonb_build_object('day', p_day, 'posted', v_posted); end if;
  for u in select r.lease_id, r.rent_due, r.pending_reported from rent_unpaid(p_day) r
  loop
    continue when u.pending_reported >= u.rent_due;                     -- a payment is pending: hold
    select l.late_fee into v_fee from leases l where l.id = u.lease_id and l.status = 'active' and l.start_date < v_month;
    continue when v_fee is null or v_fee <= 0;
    continue when exists (select 1 from fee_deletions fd where fd.lease_id = u.lease_id and fd.month = v_month and fd.gl_account = 'Late Fee Income');   -- staff deleted this month's fee
    continue when exists (select 1 from lease_ledger_entries e where e.lease_id = u.lease_id and e.gl_account = 'Late Fee Income'
                          and e.kind = 'charge' and e.entry_date >= v_month and e.entry_date <= p_day);   -- already charged this month
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (u.lease_id, 'Late Fee Income', p_day, 'charge', 'Charge', 'Late fee: rent due on the 1st was not paid', v_fee, 'rent_cycle');
    v_posted := v_posted || jsonb_build_array(jsonb_build_object('lease_id', u.lease_id, 'amount', v_fee));
  end loop;
  return jsonb_build_object('day', p_day, 'posted', v_posted);
end;
$function$;
CREATE OR REPLACE FUNCTION public.condo_post_late_fees(p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d int := extract(day from p_day);
  flat_day int := condo_setting('dues_late_flat_day', '10')::int;
  pct_day int := condo_setting('dues_late_pct_day', '11')::int;
  flat numeric := condo_setting('dues_late_flat', '25')::numeric;
  pct numeric := condo_setting('dues_late_pct', '1.15')::numeric;
  pct_base text := condo_setting('dues_late_pct_base', 'balance');
  v_annual numeric := condo_setting('dues_interest_annual_pct', '4.5')::numeric;
  v_eff date := condo_setting('dues_interest_effective', '2026-10-08')::date;
  r record; v_hold boolean; v_held numeric; v_month date := date_trunc('month', p_day)::date; v_base numeric; v_fee numeric; v_credits numeric; n_flat int := 0; n_pct int := 0;
begin
  -- Catch-up: every day from the flat-fee day to month end, each fee at most once per account per month, so a fee held back
  -- while a payment was processing posts the day the payment fails.
  if d < flat_day then return jsonb_build_object('day', p_day, 'late_fees', 0); end if;
  -- Before the effective date: the old percentage rule, so history is never recomputed differently.
  if p_day < v_eff and pct_base = 'assessments_simple' then pct_base := 'balance'; end if;
  for r in select a.id, condo_account_balance(a.id, p_day) as bal from condo_ledger_accounts a where a.billing_account and not a.excluded
  loop
    -- A payment still processing (bank payment in flight, or a recent "I've paid" report) holds the fee back: the owner paid on time.
    v_held := coalesce((select sum(s.amount) from stripe_payments s where s.condo_account_id = r.id and s.status = 'processing'), 0)
            + coalesce((select sum(pr.amount) from payment_reports pr where pr.condo_account_id = r.id and pr.status = 'pending' and payment_report_fresh(pr, p_day)), 0);
    -- Unit whose tenant pays rent into ROCA1's account: that tenant's pending rent also holds the fee (the account is paused until it clears).
    v_held := v_held + coalesce((select roca_unit_pending_rent(u2.unit_number, p_day) from condo_ledger_accounts a2 join condo_units u2 on u2.id = a2.unit_id where a2.id = r.id), 0);
    v_hold := exists (select 1 from condo_late_holds where account_id = r.id and month = v_month);
    if r.bal <= 0 then
      if v_hold then delete from condo_late_holds where account_id = r.id and month = v_month; end if;   -- the pending payment cleared: nothing owed
      continue;
    end if;
    continue when not (d = flat_day or d = pct_day or v_hold);
    if r.bal - v_held <= 0 then   -- still pending: hold, and remember it so the fee follows if the payment fails
      insert into condo_late_holds (account_id, month) values (r.id, v_month) on conflict do nothing;
      continue;
    end if;
    if (d = flat_day or v_hold) and flat > 0 and not exists (select 1 from fee_deletions fd where fd.condo_account_id = r.id and fd.month = v_month and fd.gl_account = 'Late Fee Income') and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                  and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description = 'Late fee') then
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
      values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee', flat, 'billing', 'monthly billing');
      n_flat := n_flat + 1;
    end if;
    continue when not (d = pct_day or (v_hold and d >= pct_day));
    if pct_base = 'assessments_simple' then
      -- Simple interest on unpaid assessments that were due before today; all payments and credits applied to them first.
      continue when v_annual <= 0 or exists (select 1 from fee_deletions fd where fd.condo_account_id = r.id and fd.month = v_month and fd.gl_account = 'Interest Income') or exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Interest Income'
                                                and entry_date >= v_month and entry_date <= p_day and origin = 'billing');
      select coalesce(sum(amount) filter (where amount > 0 and gl_account in ('Association Fee Income', 'Association Dues', 'Special Assessment') and entry_date < p_day), 0),
             coalesce(-sum(amount) filter (where amount < 0), 0)
        into v_base, v_credits
        from condo_ledger_entries where account_id = r.id and entry_date <= p_day;
      v_base := greatest(v_base - v_credits, 0);
      v_fee := round(v_base * v_annual / 100 / 12, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
        values (r.id, 'Interest Income', p_day, 'charge', 'Charge',
                'Interest ' || v_annual || '% a year on unpaid assessments of ' || to_char(v_base, 'FM$999,999,990.00') || ' (one month)', v_fee, 'billing', 'monthly billing',
                'By-Laws 2020 §1500(3) rate; Wis. Stat. § 703.165. Simple interest, not charged on late fees, fines or earlier interest.');
        n_pct := n_pct + 1;
      end if;
    elsif pct > 0 and not exists (select 1 from fee_deletions fd where fd.condo_account_id = r.id and fd.month = v_month and fd.gl_account = 'Late Fee Income') and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                    and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description like 'Late fee %') then
      v_base := case when pct_base = 'charges'
                     then (select coalesce(sum(amount), 0) from condo_ledger_entries where account_id = r.id and entry_date <= p_day
                           and not (gl_account = 'Late Fee Income' and amount > 0))
                     else condo_account_balance(r.id, p_day) end;
      v_fee := round(v_base * pct / 100, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
        values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee ' || pct || '% of ' || to_char(v_base, 'FM$999,999,990.00'), v_fee, 'billing', 'monthly billing');
        n_pct := n_pct + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('day', p_day, 'flat_fees', n_flat, 'percent_fees', n_pct, 'rule', pct_base);
end;
$function$;
