-- Agency payments posted automatically on the 1st, with an email to staff to verify (Stephen, 11/1/2026).
-- A housing_assistance record can be set to "auto payment". On the 1st, right after the rent charges and the agency share are posted
-- (rent-cycle job "agency_payments", 12:01 AM Central), the agency's expected payment for that month is posted on the agency ledger as
-- an agency payment (method EFT), flagged auto_posted, and one email goes to the office listing every line to verify against the
-- agency's own payment notification (for example the Center for Veterans Issues EFT notice). Staff then press "Verified" on
-- https://2ndchinc.org/accounting/assistance/ , or use Adjust if the money did not come. Nothing touches the tenant's ledger.
-- No new table, so no new grants are needed.

alter table housing_assistance add column if not exists auto_payment boolean not null default false;
alter table assistance_ledger add column if not exists auto_posted boolean not null default false;
alter table assistance_ledger add column if not exists verified_at timestamptz;
alter table assistance_ledger add column if not exists verified_by text;

-- Called by rent-cycle on the 1st (service role only). Idempotent: a month's payment is posted once, and not at all if staff already
-- recorded a payment covering what is due that month.
create or replace function assistance_auto_post(p_day date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance; v_m date := date_trunc('month', p_day)::date; v_due numeric; v_paid numeric; v_amt numeric;
  v_rows text := ''; v_missing text := ''; v_n int := 0; v_total numeric := 0; v_label text; v_to text; v_line bigint;
begin
  for a in select * from housing_assistance where status = 'active' and auto_payment and start_date <= p_day and (end_date is null or end_date >= p_day) order by agency_name, id loop
    select coalesce(sum(amount), 0) into v_due from assistance_ledger where assistance_id = a.id and kind = 'due' and entry_date >= v_m and entry_date < v_m + interval '1 month';
    select coalesce(-sum(amount), 0) into v_paid from assistance_ledger where assistance_id = a.id and kind = 'payment' and entry_date >= v_m and entry_date < v_m + interval '1 month';
    select 'Unit ' || ru.unit_number || ' (' || coalesce(l.tenants_label, '') || ')' into v_label from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id;
    if v_due <= 0 then
      v_missing := v_missing || '<li>' || replace(replace(coalesce(v_label, ''), '&', '&amp;'), '<', '&lt;') || ': the agency share for this month was not posted, so no payment was added.</li>';
      continue;
    end if;
    v_amt := v_due - v_paid;
    if v_amt <= 0 then continue; end if;
    insert into assistance_ledger (assistance_id, lease_id, entry_date, kind, amount, method, reference, description, created_by, auto_posted)
    values (a.id, a.lease_id, p_day, 'payment', -round(v_amt, 2), 'eft', 'Auto-posted: verify',
            'Expected payment from ' || a.agency_name || ' (posted automatically on the 1st, waiting for staff to verify)', 'system', true)
    returning id into v_line;
    v_n := v_n + 1; v_total := v_total + round(v_amt, 2);
    v_rows := v_rows || '<tr><td style="padding:4px 10px 4px 0">' || replace(replace(replace(a.agency_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
      || '</td><td style="padding:4px 10px 4px 0">' || replace(replace(coalesce(v_label, ''), '&', '&amp;'), '<', '&lt;') || '</td><td style="padding:4px 0;text-align:right">$'
      || to_char(round(v_amt, 2), 'FM999,990.00') || '</td></tr>';
  end loop;
  if v_n > 0 or v_missing <> '' then
    for v_to in select email from portal_admins loop
      insert into email_outbox (to_email, subject, html, kind) values (v_to,
        case when v_n > 0 then 'Please verify ' || v_n || ' agency payment' || case when v_n = 1 then '' else 's' end || ' posted today' else 'Agency payment problem on the 1st' end,
        '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Good morning,</p>'
        || case when v_n > 0 then '<p>The system posted these expected agency payments on the 1st (' || to_char(p_day, 'FMMM/FMDD/YYYY') || '). They are on the agency ledger only; the tenant ledgers did not change.</p>'
             || '<table style="border-collapse:collapse;font-size:14px">' || v_rows || '</table>'
             || '<p><b>Please verify each one</b> against the agency''s own payment notification email (for example the Center for Veterans Issues EFT notice, which names an invoice and the amount). If it matches, open the page below and press <b>Verified</b> on the line. If the money did not arrive or the amount differs, use <b>Adjust / write off</b> on the same page.</p>' else '' end
        || case when v_missing <> '' then '<p><b>Needs your attention:</b></p><ul>' || v_missing || '</ul>' else '' end
        || '<p><a href="https://2ndchinc.org/accounting/assistance/">Open Housing assistance</a></p><p style="color:#5b6573;font-size:13px">2nd Chance Housing</p></div>',
        'assistance_verify');
    end loop;
  end if;
  return jsonb_build_object('posted', v_n, 'total', v_total, 'missing_share', v_missing <> '');
end $$;
revoke all on function assistance_auto_post(date) from public, anon, authenticated;
grant execute on function assistance_auto_post(date) to service_role;

-- Staff: mark an auto-posted agency payment as checked against the agency's notice.
create or replace function assistance_staff_verify(p_line bigint)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x assistance_ledger;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update assistance_ledger set verified_at = now(), verified_by = lower(auth.email()), reference = 'Verified ' || to_char(now() at time zone 'America/Chicago', 'FMMM/FMDD/YYYY')
  where id = p_line and kind = 'payment' and auto_posted and verified_at is null returning * into x;
  if x.id is null then raise exception 'That line is not waiting to be verified.'; end if;
  return jsonb_build_object('verified', x.id);
end $$;
revoke all on function assistance_staff_verify(bigint) from public, anon;
grant execute on function assistance_staff_verify(bigint) to authenticated;

-- Staff: turn the automatic payment on or off for a record.
create or replace function assistance_staff_set_auto(p_id uuid, p_on boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update housing_assistance set auto_payment = coalesce(p_on, false), updated_by = lower(auth.email()), updated_at = now() where id = p_id returning * into a;
  if a.id is null then raise exception 'Record not found'; end if;
  return jsonb_build_object('auto_payment', a.auto_payment);
end $$;
revoke all on function assistance_staff_set_auto(uuid, boolean) from public, anon;
grant execute on function assistance_staff_set_auto(uuid, boolean) to authenticated;
