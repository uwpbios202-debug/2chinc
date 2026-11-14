-- Association interest at the By-Laws rate, going forward (Stephen, 10/7/2026: "make the changes, keep the historical
-- amounts and change it going forward").
--
-- Wis. Stat. § 703.165: an assessment not paid when due bears interest "at a rate not exceeding the highest rate
-- permitted by law as stated in the bylaws". ROCA1 By-Laws 2020 §1500(3): unpaid charges "shall bear interest at the
-- rate of four point five percent (4.5%) per annum until paid in full."
--
-- Before: on the 11th, 1.15% of the WHOLE balance (late fees and earlier interest included, so it compounded) — the
-- way it was previously configured (20261026000000_association_dues). That is about 14.7% a year, above the By-Laws rate.
-- From 10/8/2026: on the 11th, simple interest of 4.5% a year (0.375% a month) on unpaid ASSESSMENTS only (dues and
-- special assessments) — never on late fees, fines or earlier interest, so it does not compound. Payments and credits
-- count against assessments first (the lowest interest base). The $25 late fee on the 10th (Rules 2024 §11) stays.
--
-- Every entry already on the ledgers is kept exactly as it is. Days before the effective date still compute the old
-- way, so a re-run for a past day can't rewrite history.

insert into portal_settings (key, value) values
  ('dues_interest_annual_pct', '4.5'),
  ('dues_interest_effective', '2026-10-08')
on conflict (key) do nothing;
update portal_settings set value = 'assessments_simple' where key = 'dues_late_pct_base';

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
  r record; v_base numeric; v_fee numeric; v_credits numeric; n_flat int := 0; n_pct int := 0;
begin
  if d <> flat_day and d <> pct_day then return jsonb_build_object('day', p_day, 'late_fees', 0); end if;
  -- Before the effective date: the earlier percentage rule, so history is never recomputed differently.
  if p_day < v_eff and pct_base = 'assessments_simple' then pct_base := 'balance'; end if;
  for r in select a.id, condo_account_balance(a.id, p_day) as bal from condo_ledger_accounts a where a.billing_account and not a.excluded
  loop
    continue when r.bal <= 0;
    if d = flat_day and flat > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                  and entry_date = p_day and origin = 'billing' and description = 'Late fee') then
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
      values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee', flat, 'billing', 'monthly billing');
      n_flat := n_flat + 1;
    end if;
    continue when d <> pct_day;
    if pct_base = 'assessments_simple' then
      -- Simple interest on unpaid assessments that were due before today; all payments and credits applied to them first.
      continue when v_annual <= 0 or exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Interest Income'
                                                and entry_date = p_day and origin = 'billing');
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
                                    and entry_date = p_day and origin = 'billing' and description like 'Late fee %') then
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
