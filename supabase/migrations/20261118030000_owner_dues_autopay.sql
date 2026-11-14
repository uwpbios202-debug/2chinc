-- Owner dues auto-pay (Stephen, 11/2/2026). A flagged unit has its monthly association dues paid on the 1st, right after the charge is
-- posted. Mode is a payment, or a credit up to credit_until. A unit with end_month null is perpetual: each month the office gets an
-- email asking whether perpetual ends the following month. Posted lines are origin 'autopay'. Nothing here touches older months.
create table if not exists owner_dues_autopay (
  unit_id uuid primary key references condo_units(id),
  credit_until date,          -- months up to and including this one are posted as a credit, later months as a payment
  end_month date,             -- last month auto-paid; null = perpetual
  note text,
  created_at timestamptz not null default now()
);
alter table owner_dues_autopay enable row level security;
grant all on owner_dues_autopay to service_role;

create or replace function condo_dues_autopay_post(p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  m date := date_trunc('month', p_month)::date; r record; v_acct uuid; v_charge numeric; v_bal numeric; v_amt numeric; v_credit boolean;
  n int := 0; v_perp text := ''; v_last text := ''; v_to text;
begin
  for r in select f.*, u.unit_number from owner_dues_autopay f join condo_units u on u.id = f.unit_id
           where (f.end_month is null or f.end_month >= m)
             and exists (select 1 from condo_ownerships s where s.unit_id = f.unit_id and s.is_current)
           order by u.unit_number::int
  loop
    v_acct := condo_billing_account(r.unit_id);
    if exists (select 1 from condo_ledger_entries e where e.account_id = v_acct and e.origin = 'autopay' and date_trunc('month', e.entry_date) = m) then continue; end if;
    select coalesce(sum(e.amount), 0) into v_charge from condo_ledger_entries e
      where e.account_id = v_acct and e.kind = 'charge' and e.gl_account = 'Association Fee Income' and date_trunc('month', e.entry_date) = m;
    if v_charge <= 0 then continue; end if;
    v_bal := condo_account_balance(v_acct);
    v_amt := least(v_charge, v_bal);
    if v_amt <= 0 then continue; end if;
    v_credit := r.credit_until is not null and m <= date_trunc('month', r.credit_until)::date;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note)
    values (v_acct, 'Association Fee Income', m, case when v_credit then 'credit' else 'payment' end,
            case when v_credit then 'Credit' else 'Payment (other)' end, case when v_credit then null else 'other' end,
            case when v_credit then 'Credit' else 'Payment' end, -v_amt, 'autopay', 'dues auto-pay',
            case when v_credit then 'Owner dues auto-credit (Stephen, 11/2/2026)' else 'Owner dues auto-pay (Stephen, 11/2/2026)' end);
    n := n + 1;
    if r.end_month is null then v_perp := v_perp || '<li>Unit ' || r.unit_number || '</li>';
    elsif r.end_month = m then v_last := v_last || '<li>Unit ' || r.unit_number || '</li>'; end if;
  end loop;
  if v_perp <> '' or v_last <> '' then
    for v_to in select email from portal_admins loop
      insert into email_outbox (to_email, subject, html, kind) values (v_to,
        'Owner dues auto-pay posted for ' || to_char(m, 'FMMM/FMYYYY'),
        '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Good morning,</p>'
        || '<p>The owner dues for ' || to_char(m, 'FMMM/FMYYYY') || ' were paid automatically.</p>'
        || case when v_perp <> '' then '<p>These units are on <b>perpetual</b> auto-pay: <ul>' || v_perp || '</ul>Does perpetual end next month? If so, tell info@2ndchinc.org (reply to this email) and the end date will be set.</p>' else '' end
        || case when v_last <> '' then '<p>This was the <b>last</b> auto-pay month for: <ul>' || v_last || '</ul>From next month these dues stay owed.</p>' else '' end
        || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing</p></div>', 'dues_autopay');
    end loop;
  end if;
  return jsonb_build_object('month', m, 'autopaid', n);
end $$;
revoke all on function condo_dues_autopay_post(date) from public, anon, authenticated;
grant execute on function condo_dues_autopay_post(date) to service_role;

-- Run it right after the month's charges (same body as before, plus one call at the end).
create or replace function condo_billing_post_month(p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare m date := date_trunc('month', p_month)::date; r record; v_acct uuid; n int := 0; skipped int := 0; v_auto jsonb;
begin
  for r in select s.unit_id, coalesce(s.fee, condo_setting('dues_default', '215')::numeric) as fee, s.fee_frequency
           from condo_ownerships s where s.is_current and coalesce(s.start_date, m) <= m + 27
  loop
    if coalesce(r.fee_frequency, 'Monthly') <> 'Monthly' or r.fee <= 0 then skipped := skipped + 1; continue; end if;
    v_acct := condo_billing_account(r.unit_id);
    if exists (select 1 from condo_ledger_entries e where e.account_id = v_acct and e.kind = 'charge'
               and e.gl_account = 'Association Fee Income' and date_trunc('month', e.entry_date) = m) then
      skipped := skipped + 1; continue;
    end if;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
    values (v_acct, 'Association Fee Income', m, 'charge', 'Charge', 'Association Fees', r.fee, 'billing', 'monthly billing');
    n := n + 1;
  end loop;
  v_auto := condo_dues_autopay_post(m);
  return jsonb_build_object('month', m, 'dues_charges', n, 'skipped', skipped, 'autopay', v_auto);
end;
$$;
revoke all on function condo_billing_post_month(date) from public, anon, authenticated;

-- The flagged units. Units 2, 3, 4, 5, 11, 14: through 12/1/2028. Units 13, 15, 17: perpetual; Unit 13 is a credit through 6/2027.
insert into owner_dues_autopay (unit_id, credit_until, end_month, note)
select u.id, case when u.unit_number = '13' then date '2027-06-01' end,
       case when u.unit_number in ('13', '15', '17') then null else date '2028-12-01' end,
       'Stephen, 11/2/2026'
from condo_units u where u.unit_number in ('2', '3', '4', '5', '11', '13', '14', '15', '17')
on conflict (unit_id) do nothing;
