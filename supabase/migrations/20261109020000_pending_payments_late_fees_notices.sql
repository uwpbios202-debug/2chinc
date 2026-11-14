-- Pending payments (Stephen, 10/11/2026):
--  * Owners have until 11:59 PM on the 10th. The $25 late fee now posts on the 11th (it posted on the 10th, so a payment made on
--    the 10th was already charged), and the monthly interest on the 12th (one day after the fee, as before).
--  * A payment still PENDING (a bank payment in flight, or a fresh "I've paid" report) holds the late fee back. When it clears
--    nothing more happens; when it fails the fee posts that day (see rent-cycle "catchup"). Fees now run every day from the fee
--    day to month end, at most once per account per month, instead of on two fixed days.
--  * A bank payment is dated the day the person paid (Central), not the day it cleared.
--  * Tenants: a pay-or-vacate notice is never prepared while a payment is pending. When the hold ends (bank payment failed, report
--    rejected or stale) the notice is prepared right then (rent-cycle "catchup" + daily), no longer only on the 2nd.

-- Accounts whose late fee was held back because a payment was pending on the fee day. Only these get the fee later in the month
-- (when that payment fails); everyone else is judged on the fee day alone, so a charge added mid-month never triggers a late fee.
create table if not exists condo_late_holds (
  account_id uuid not null references condo_ledger_accounts(id) on delete cascade,
  month date not null,
  primary key (account_id, month)
);
alter table condo_late_holds enable row level security;   -- service/definer only

insert into portal_settings (key, value) values ('dues_late_flat_day', '11'), ('dues_late_pct_day', '12')
on conflict (key) do update set value = excluded.value;

create or replace function condo_post_late_fees(p_day date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
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
  -- Before the effective date: the earlier percentage rule, so history is never recomputed differently.
  if p_day < v_eff and pct_base = 'assessments_simple' then pct_base := 'balance'; end if;
  for r in select a.id, condo_account_balance(a.id, p_day) as bal from condo_ledger_accounts a where a.billing_account and not a.excluded
  loop
    -- A payment still processing (bank payment in flight, or a recent "I've paid" report) holds the fee back: the owner paid on time.
    v_held := coalesce((select sum(s.amount) from stripe_payments s where s.condo_account_id = r.id and s.status = 'processing'), 0)
            + coalesce((select sum(pr.amount) from payment_reports pr where pr.condo_account_id = r.id and pr.status = 'pending' and payment_report_fresh(pr, p_day)), 0);
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
    if (d = flat_day or v_hold) and flat > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                  and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description = 'Late fee') then
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
      values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee', flat, 'billing', 'monthly billing');
      n_flat := n_flat + 1;
    end if;
    continue when not (d = pct_day or (v_hold and d >= pct_day));
    if pct_base = 'assessments_simple' then
      -- Simple interest on unpaid assessments that were due before today; all payments and credits applied to them first.
      continue when v_annual <= 0 or exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Interest Income'
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
    elsif pct > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
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
$$;

create or replace function stripe_payment_succeeded(p_intent text, p_method_type text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare s stripe_payments; v_report uuid;
begin
  select * into s from stripe_payments where payment_intent = p_intent for update;
  if s.id is null then return jsonb_build_object('error', 'unknown payment intent'); end if;
  if s.status = 'succeeded' then return jsonb_build_object('ok', true, 'already', true); end if;
  insert into payment_reports (tenant_id, owner_id, condo_account_id, lease_id, land_contract_id, method, amount, paid_on, confirmation_code, note)
  values (s.tenant_id, s.owner_id, s.condo_account_id, s.lease_id, s.land_contract_id,
          case when coalesce(p_method_type, s.method_type) = 'card' then 'stripe_card' else 'stripe_bank' end,
          s.amount, (s.created_at at time zone 'America/Chicago')::date, p_intent, case when s.owner_id is not null then 'Association dues paid online' when s.origin = 'autopay' then 'Autopay' else 'Paid online' end)
  returning id into v_report;
  perform payment_post(v_report, null, 'stripe', 'Stripe');
  update stripe_payments set status = 'succeeded', method_type = coalesce(p_method_type, method_type), payment_report_id = v_report, updated_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'report', v_report);
end;
$$;
