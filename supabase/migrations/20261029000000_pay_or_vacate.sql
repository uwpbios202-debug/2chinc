-- Our own notice to pay rent or vacate, replacing the two earlier versions
-- (they showed the monthly rent instead of what's actually unpaid, a $0.00
-- earlier balance, ZIP 53206, and one carried a Rice Lake address).
--
-- One template; the lease decides the rest (lease_notice_rules):
--   5 days   month-to-month (§ 704.17(1p)(a)) or a lease of a year or less (§ 704.17(2)(a))
--   30 days  a lease longer than a year (§ 704.17(3)), or a Section 8 / federally
--            covered tenancy (CARES Act § 4024(c), 15 U.S.C. § 9058(c); HUD)
-- The notice states the unpaid rent (this month and earlier months), the
-- amount required, and an exact deadline. RENT ONLY: no late fees or other
-- charges appear in the notice or its email (Stephen, 10/4/2026).
--
-- Service (§ 704.21): plain mail alone is not valid service; certified mail
-- is. The certified-mail stamp date is day 1 (as Milwaukee judges count it;
-- Stephen, 10/4/2026), so a 5-day notice mailed 10/2 runs through 10/6.
-- Checked against Wis. Stat. ch. 704 as published 10/1/2026.

insert into portal_settings (key, value) values
  ('notice_service', 'certified_mail'),      -- certified_mail | personal
  ('notice_mail_days', '0')                  -- days after mailing before day 1 (0: the stamp date is day 1)
on conflict (key) do nothing;

insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields, email_subject, email_html, law_ref, law_checked_on) values
('2c-pay-or-vacate', 'Tenant', '2nd Chance — Notice to Pay Rent or Vacate', 'Notice to Pay Rent or Vacate',
 'Made by the rent cycle on the 2nd (or from a lease on the Notices page). 5 or 30 days, set by the lease.',
 '<p style="text-align: center"><strong>[[Notice_Title]]</strong></p>
<p style="text-align: center">[[Notice_Statute]]</p>
<p>[[Notice_Date]]</p>
<p>Landlord: [[Landlord_Line]]. [[Landlord_Address]]. Managing agent: 2nd Chance Housing Inc.</p>
<p>To: [[Lease_All_Tenants]]<br>[[Unit_Address]]</p>
<p>Premises: [[Unit_Address]]</p>
<p>Your rent is past due. This notice ends your tenancy unless you pay the rent owed. You must pay <b>[[Amount_Required]]</b> on or before <b>[[Deadline]]</b>, or move out of the premises by that date. If you do neither, the landlord may file an eviction action against you.</p>
[[Federal_Paragraph]]
<p><b>How the amount was calculated:</b></p>
<ul><li>Rent unpaid for [[Rent_Month]]: [[Current_Unpaid]]</li>
<li>Unpaid rent from earlier months: [[Prior_Unpaid]]</li>
<li><b>Total unpaid rent required: [[Amount_Required]]</b></li></ul>
<p><b>How to pay:</b> in your resident portal ([[Portal_URL]]), by Zelle to [[Zelle_Name]], or by check or money order mailed or delivered to [[Landlord_Address]]. Call [[Org_Phone]] if you need to talk about it.</p>
<p><b>Partial payment.</b> If you pay less than [[Amount_Required]] by the deadline, this notice is not cancelled unless the landlord agrees in writing.</p>
<p><b>Double rent.</b> If you stay after your tenancy ends, Wisconsin law (§ 704.27) allows the landlord to recover at least twice the daily rent for each day you remain.</p>
<p><b>Credit reporting.</b> Unpaid accounts may be reported to credit bureaus, which can affect your ability to get credit or rent in the future.</p>
<p>Served by [[Service_Method]] on [[Mail_Date]].</p>
<p>Dated at Milwaukee, Wisconsin, [[Notice_Date]].</p>
<p>[[Sender_Signature]]</p>
<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]</p>',
 array['Notice_Title', 'Notice_Statute', 'Notice_Date', 'Landlord_Line', 'Landlord_Address', 'Lease_All_Tenants', 'Unit_Address', 'Amount_Required', 'Deadline',
   'Federal_Paragraph', 'Rent_Month', 'Current_Unpaid', 'Prior_Unpaid', 'Portal_URL', 'Zelle_Name', 'Org_Phone', 'Service_Method',
   'Mail_Date', 'Sender_Signature', 'Agent_Name', 'Agent_Title', 'Landlord_Signoff'],
 'Notice to pay rent or vacate — [[Unit_Address]]',
 '<p>Dear [[FIRST]],</p>
<p>Your rent for [[Unit_Address]] is past due. Attached is a [[Notice_Days]]-day notice to pay rent or vacate. The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy.</p>
<p>To keep your home, pay <b>[[Amount_Required]]</b> on or before <b>[[Deadline]]</b>. You can pay by Zelle to [[Zelle_Name]] or in your <a href="[[Portal_URL]]">resident portal</a>, then tap "I''ve paid".</p>
<p>If you already paid, tap "I''ve paid" in the portal so we can match it. If you need to talk about it, call [[Org_Phone]].</p>
<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]<br>2nd Chance Housing Inc., managing agent</p>',
 'Wis. Stat. §§ 704.17, 704.21, 704.27; CARES Act § 4024(c)', '2026-10-04')
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name,
  email_subject = excluded.email_subject, email_html = excluded.email_html, law_ref = excluded.law_ref, law_checked_on = excluded.law_checked_on, active = true;

-- The earlier pay-or-quit versions are retired.
update letter_templates set active = false where name in ('01_ROCA1_5day_balance', '02_Pay Rent or Quit - ROCA1', 'Notice to Pay Rent or Quit - RH');

-- Build the notice for one lease, mailed (or handed over) on p_mail_on.
create or replace function pay_or_vacate_notice(p_lease uuid, p_mail_on date, p_sender_email text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  l leases; r jsonb; s jsonb; v_days int; v_given date; v_deadline date; v_month date;
  v_due numeric; v_cur_charge numeric; v_cur numeric; v_prior numeric;
  v_service text; v_title text; v_statute text; v_fed text := ''; v_extra jsonb; v_html text; v_email text; v_subject text;
  money_ text := 'FM$999,990.00';
begin
  select * into l from leases where id = p_lease;
  if l.id is null then raise exception 'Lease not found'; end if;
  select jsonb_object_agg(key, value) into s from portal_settings;
  r := lease_notice_rules(l.id);
  v_days := (r->>'nonpayment_days')::int;
  v_service := coalesce(s->>'notice_service', 'certified_mail');
  v_given := p_mail_on + case when v_service = 'personal' then 0 else coalesce((s->>'notice_mail_days')::int, 0) end;
  v_deadline := v_given + v_days - 1;   -- the day given is day 1
  v_month := date_trunc('month', p_mail_on)::date;

  v_due := lease_rent_due(l.id, p_mail_on);
  select coalesce(sum(amount), 0) into v_cur_charge from lease_ledger_entries
    where lease_id = l.id and kind = 'charge' and gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', entry_date) = v_month;
  v_cur := least(v_due, greatest(v_cur_charge, 0));
  v_prior := v_due - v_cur;

  v_title := case v_days when 5 then 'FIVE-DAY NOTICE TO PAY RENT OR VACATE' when 30 then 'THIRTY-DAY NOTICE TO PAY RENT OR VACATE' else v_days || '-DAY NOTICE TO PAY RENT OR VACATE' end;
  v_statute := case
    when l.federal_program is not null then 'Wis. Stat. § 704.17 and CARES Act § 4024(c), 15 U.S.C. § 9058(c)'
    when r->>'lease_kind' = 'fixed_over_1_year' then 'Wis. Stat. § 704.17(3)'
    when r->>'lease_kind' = 'month_to_month' then 'Wis. Stat. § 704.17(1p)(a)'
    else 'Wis. Stat. § 704.17(2)(a)' end;
  if l.federal_program is not null then
    v_fed := '<p>Because your tenancy is ' || case when l.federal_program = 'section8' then 'under the Section 8 Housing Choice Voucher program' else 'federally covered' end ||
      ', federal law requires at least 30 days'' notice before you can be required to vacate for nonpayment. This notice gives you 30 days.</p>';
  end if;

  v_extra := jsonb_build_object('_keep_signature', true, 'Tenant_First_Name', '[[FIRST]]',
    'Notice_Title', v_title, 'Notice_Statute', v_statute, 'Notice_Days', v_days::text,
    'Notice_Date', to_char(p_mail_on, 'FMMonth FMDD, YYYY'), 'Mail_Date', to_char(p_mail_on, 'FMMonth FMDD, YYYY'),
    'Deadline', to_char(v_deadline, 'FMDay, FMMonth FMDD, YYYY'),
    'Service_Method', case v_service when 'personal' then 'personal delivery' else 'certified mail' end,
    'Rent_Month', to_char(v_month, 'FMMonth YYYY'), 'Current_Unpaid', to_char(v_cur, money_), 'Prior_Unpaid', to_char(v_prior, money_),
    'Amount_Required', to_char(v_due, money_),
    'Federal_Paragraph', '[[FED]]');
  v_html := replace(letter_fill((select html from letter_templates where legacy_id = '2c-pay-or-vacate'), l.id, v_extra), '[[FED]]', v_fed);
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where legacy_id = '2c-pay-or-vacate';

  return jsonb_build_object('template_id', (select id from letter_templates where legacy_id = '2c-pay-or-vacate'), 'template_name', '2nd Chance — Notice to Pay Rent or Vacate',
    'subject', case v_days when 5 then 'Five-Day Notice to Pay Rent or Vacate' when 30 then 'Thirty-Day Notice to Pay Rent or Vacate' else v_days || '-Day Notice to Pay Rent or Vacate' end, 'html', v_html, 'email_subject', v_subject, 'email_html', v_email,
    'days', v_days, 'given_on', v_given, 'deadline', v_deadline, 'amount_required', v_due,
    'federal_program', l.federal_program, 'basis', r->>'nonpayment_basis');
end;
$$;
revoke all on function pay_or_vacate_notice(uuid, date, text) from public, anon, authenticated;
grant execute on function pay_or_vacate_notice(uuid, date, text) to service_role;
grant execute on function lease_notice_rules(uuid) to service_role;

-- Staff: the same notice for one lease from the Notices page.
create or replace function notice_staff_pay_or_vacate(p_lease uuid, p_mail_on date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if lease_rent_due(p_lease, coalesce(p_mail_on, current_date)) <= 0 then raise exception 'This lease has no unpaid rent.'; end if;
  return pay_or_vacate_notice(p_lease, coalesce(p_mail_on, current_date), auth.email());
end;
$$;
revoke all on function notice_staff_pay_or_vacate(uuid, date) from public, anon;
grant execute on function notice_staff_pay_or_vacate(uuid, date) to authenticated;

-- A drafted notice keeps its own email until the agent signs it; signing sends it.
alter table notices add column if not exists email_subject text;
alter table notices add column if not exists email_html text;
