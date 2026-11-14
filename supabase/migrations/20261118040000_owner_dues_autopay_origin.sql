-- Fix: the ledger only allows origin opening/billing/staff, so auto-pay lines use origin 'staff' with entered_by 'dues auto-pay'.
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
    if exists (select 1 from condo_ledger_entries e where e.account_id = v_acct and e.entered_by = 'dues auto-pay' and date_trunc('month', e.entry_date) = m) then continue; end if;
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
            case when v_credit then 'Credit' else 'Payment' end, -v_amt, 'staff', 'dues auto-pay',
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
