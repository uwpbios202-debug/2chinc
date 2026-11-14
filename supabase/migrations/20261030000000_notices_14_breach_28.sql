-- Our own termination notices, built from the lease (like the pay-or-vacate
-- notice) and made from the Notices page:
--   2c-breach-cure   remedy a breach or vacate: 5 days (§ 704.17(1p)(b), (2)(b));
--                    30 days for a lease over a year (§ 704.17(3))
--   2c-14-day        14-day notice to vacate, no right to cure, for unpaid rent
--                    or a breach: month-to-month any time (§ 704.17(1p)(a), (b));
--                    a lease of a year or less only within a year of an earlier
--                    notice (§ 704.17(2)(a), (b)); never a lease over a year, and
--                    never for unpaid rent in a federally covered tenancy
--   2c-28-day        ends a month-to-month tenancy at the end of a month, at least
--                    28 days after the notice is given (§ 704.19)
-- House rules (Stephen, 10/4/2026): certified mail; the stamp date is day 1;
-- rent-based notices state rent only, never fees. Every notice names the
-- landlord the same way (ROCA1 for the unit owner on condo units).
-- Section 8: the housing authority gets a copy of every notice, and ending a
-- voucher tenancy needs a stated cause (HAP contract), so the 28-day notice
-- asks for it.

alter table letter_templates add column if not exists built boolean not null default false;   -- made by a builder, not filled by hand
update letter_templates set built = true where legacy_id = '2c-pay-or-vacate';

-- The Notices page needs to know which templates are built.
create or replace function letter_templates_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'key', legacy_id, 'built', built, 'recipient', recipient, 'name', name, 'subject', subject,
      'description', description, 'html', html, 'fields', fields) order by recipient, built desc, name) from letter_templates where active), '[]'::jsonb);
end;
$$;

-- The last day a notice gives (the day it's given is day 1).
create or replace function notice_deadline(p_mail_on date, p_days int)
returns date
language sql stable security definer set search_path = public as $$
  select p_mail_on + case when coalesce((select value from portal_settings where key = 'notice_service'), 'certified_mail') = 'personal' then 0
                          else coalesce((select value::int from portal_settings where key = 'notice_mail_days'), 0) end + p_days - 1;
$$;

-- The most recent notice of this kind (rent | breach) on the lease in the year before p_on.
create or replace function notice_prior_within_year(p_lease uuid, p_kind text, p_on date)
returns date
language sql stable security definer set search_path = public as $$
  select max(coalesce(n.served_on, n.sent_at::date)) from notices n left join letter_templates t on t.id = n.template_id
  where n.lease_id = p_lease and not n.voided and n.status = 'sent' and coalesce(n.served_on, n.sent_at::date) between p_on - 365 and p_on
    and case p_kind
      when 'rent' then t.legacy_id = '2c-pay-or-vacate' or n.template_name in ('01_ROCA1_5day_balance', '02_Pay Rent or Quit - ROCA1', 'Notice to Pay Rent or Quit - RH')
      else t.legacy_id = '2c-breach-cure' or n.template_name in ('Breach', 'All Breach', '5-day Breach Pet', '5-Day-Pets', 'Breach of Utilities') end;
$$;

-- Templates -------------------------------------------------------------------------

do $$
declare
  head text := '<p style="text-align: center"><strong>[[Notice_Title]]</strong></p>
<p style="text-align: center">[[Notice_Statute]]</p>
<p>[[Notice_Date]]</p>
<p>Landlord: [[Landlord_Line]]. [[Landlord_Address]]. Managing agent: 2nd Chance Housing Inc.</p>
<p>To: [[Lease_All_Tenants]]<br>[[Unit_Address]]</p>
<p>Premises: [[Unit_Address]]</p>';
  foot text := '<p>Served by [[Service_Method]] on [[Mail_Date]].</p>
<p>Dated at Milwaukee, Wisconsin, [[Notice_Date]].</p>
<p>[[Sender_Signature]]</p>
<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]</p>';
  sign text := '<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]<br>2nd Chance Housing Inc., managing agent</p>';
  dbl text := '<p><b>Double rent.</b> If you stay after your tenancy ends, Wisconsin law (§ 704.27) allows the landlord to recover at least twice the daily rent for each day you remain.</p>';
  law text := 'Wis. Stat. §§ 704.17, 704.19, 704.21, 704.27';
begin
  insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields, email_subject, email_html, law_ref, law_checked_on, built) values
  ('2c-breach-cure', 'Tenant', '2nd Chance — Notice to Remedy Breach or Vacate', 'Notice to Remedy Breach or Vacate',
   'A lease violation other than rent: fix it or move out. 5 days (30 for a lease over a year), set by the lease.',
   head || '<p>You have broken your rental agreement ([[Provision]]): [[Breach]]</p>
<p>You must <b>remedy this breach or move out of the premises on or before [[Deadline]]</b>. To remedy it: [[Cure]]</p>
<p>If you remedy the breach by that date, your tenancy continues. If it cannot be fully remedied in that time, you must begin taking reasonable steps right away and keep at it with reasonable diligence, or make a good-faith offer to pay for any damage it caused. If you do none of these, the landlord may file an eviction action against you.</p>
[[Repeat_Text]]' || dbl || foot,
   array['Notice_Title', 'Notice_Statute', 'Notice_Date', 'Provision', 'Breach', 'Cure', 'Deadline', 'Repeat_Text', 'Service_Method', 'Mail_Date'],
   'Notice to remedy a lease violation — [[Unit_Address]]',
   '<p>Dear [[FIRST]],</p>
<p>Attached is a [[Notice_Days]]-day notice about a violation of your rental agreement at [[Unit_Address]]: [[Breach]]</p>
<p>To keep your home, remedy it on or before <b>[[Deadline]]</b>: [[Cure]]</p>
<p>The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy. If you have questions or need more time to fix something, call [[Org_Phone]] right away.</p>' || sign,
   law, '2026-10-04', true),
  ('2c-14-day', 'Tenant', '2nd Chance — 14-Day Notice to Vacate', '14-Day Notice to Vacate',
   'Ends the tenancy for unpaid rent or a breach, with no chance to cure. Month-to-month any time; a lease of a year or less only within a year of an earlier notice.',
   head || '<p>[[Reason_Text]]</p>
[[Prior_Text]]
<p><b>Your tenancy is terminated. You must move out of the premises on or before [[Deadline]].</b> This notice does not give you a right to cure. Any payment you make will be applied to what you owe, but it does not cancel this notice unless the landlord agrees in writing. If you do not move out by that date, the landlord may file an eviction action against you.</p>
<p>Please enter your forwarding address in your resident portal so we can return your security deposit, with an itemized statement of anything withheld, within 21 days as required by Wis. Stat. § 704.28.</p>' || dbl || foot,
   array['Notice_Title', 'Notice_Statute', 'Notice_Date', 'Reason_Text', 'Prior_Text', 'Deadline', 'Service_Method', 'Mail_Date'],
   '14-day notice to vacate — [[Unit_Address]]',
   '<p>Dear [[FIRST]],</p>
<p>Attached is a 14-day notice to vacate [[Unit_Address]]. [[Reason_Short]] Your tenancy ends and you must move out on or before <b>[[Deadline]]</b>.</p>
<p>The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy. Please enter your forwarding address in your <a href="[[Portal_URL]]">resident portal</a> so we can send your deposit statement. If you have questions, call [[Org_Phone]].</p>' || sign,
   law, '2026-10-04', true),
  ('2c-28-day', 'Tenant', '2nd Chance — 28-Day Notice Ending Month-to-Month Tenancy', '28-Day Notice Terminating Tenancy',
   'Ends a month-to-month tenancy at the end of a month, at least 28 days after the notice is given.',
   head || '<p>This notice ends your month-to-month tenancy of the premises. <b>Your tenancy ends at 11:59 p.m. on [[Termination_Date]].</b> You must move out and return all keys by then.</p>
[[Reason_Text]]
<p>Rent is due as usual through [[Termination_Date]].</p>
<p>Please enter your forwarding address in your resident portal so we can return your security deposit, with an itemized statement of anything withheld, within 21 days as required by Wis. Stat. § 704.28. Move-out instructions are on that page too.</p>' || dbl || foot,
   array['Notice_Title', 'Notice_Statute', 'Notice_Date', 'Termination_Date', 'Reason_Text', 'Service_Method', 'Mail_Date'],
   'Notice ending your tenancy — [[Unit_Address]]',
   '<p>Dear [[FIRST]],</p>
<p>Attached is a 28-day notice ending your month-to-month tenancy at [[Unit_Address]]. Your tenancy ends at 11:59 p.m. on <b>[[Termination_Date]]</b>; please move out and return all keys by then.</p>
<p>The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy. Please enter your forwarding address in your <a href="[[Portal_URL]]">resident portal</a> so we can send your deposit statement. If you have questions, call [[Org_Phone]].</p>' || sign,
   law, '2026-10-04', true)
  on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name,
    email_subject = excluded.email_subject, email_html = excluded.email_html, law_ref = excluded.law_ref, law_checked_on = excluded.law_checked_on, built = true, active = true;
end $$;

-- The earlier breach and 28-day versions are retired in favour of these.
update letter_templates set active = false where name in ('Breach', 'All Breach', '28 Day_ROCA', '30 Day Notice Nonrenewal');

-- Builder -------------------------------------------------------------------------
-- p_template: 2c-pay-or-vacate | 2c-breach-cure | 2c-14-day | 2c-28-day
-- p_details:  breach-cure: provision, breach, cure
--             14-day:      reason (rent | breach), breach, prior_notice_on (if not in the system)
--             28-day:      end_on (a later month-end, optional), reason (optional; required for Section 8)
create or replace function notice_build(p_template text, p_lease uuid, p_mail_on date, p_details jsonb, p_sender_email text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  l leases; r jsonb; d jsonb := coalesce(p_details, '{}'::jsonb); v_mail date := coalesce(p_mail_on, current_date);
  v_days int; v_deadline date; v_given date; v_title text; v_statute text; v_extra jsonb; v_html text; v_email text; v_subject text;
  v_prior date; v_reason text; v_due numeric; v_cur numeric; v_month date; v_warn text := ''; v_end date; v_txt text := ''; v_short text := '';
  money_ text := 'FM$999,990.00'; v_fmt text := 'FMDay, FMMonth FMDD, YYYY';
  v_service text := coalesce((select value from portal_settings where key = 'notice_service'), 'certified_mail');
  v_mm boolean;
begin
  if p_template = '2c-pay-or-vacate' then
    return pay_or_vacate_notice(p_lease, v_mail, p_sender_email) || jsonb_build_object('warning',
      case when (select federal_program from leases where id = p_lease) is not null then 'Section 8 / federal tenancy: send a copy of this notice to the housing authority.' else '' end);
  end if;
  select * into l from leases where id = p_lease;
  if l.id is null then raise exception 'Lease not found'; end if;
  r := lease_notice_rules(l.id);
  v_mm := l.lease_type = 'at_will';
  v_given := notice_deadline(v_mail, 1);
  if l.federal_program is not null then
    v_warn := 'Section 8 / federal tenancy: send a copy of this notice to the housing authority.';
  end if;

  if p_template = '2c-breach-cure' then
    if length(trim(coalesce(d->>'breach', ''))) < 10 then raise exception 'Describe the breach: what happened, where and when.'; end if;
    if length(trim(coalesce(d->>'cure', ''))) < 5 then raise exception 'Say what the tenant must do to remedy it.'; end if;
    v_days := (r->>'breach_cure_days')::int;
    v_deadline := notice_deadline(v_mail, v_days);
    v_title := case v_days when 5 then 'FIVE-DAY NOTICE TO REMEDY BREACH OR VACATE' else 'THIRTY-DAY NOTICE TO REMEDY BREACH OR VACATE' end;
    v_statute := case when r->>'lease_kind' = 'fixed_over_1_year' then 'Wis. Stat. § 704.17(3)' when v_mm then 'Wis. Stat. § 704.17(1p)(b)' else 'Wis. Stat. § 704.17(2)(b)' end;
    v_txt := case when r->>'lease_kind' = 'fixed_over_1_year' then '' else
      '<p>If, within one year of this notice, you break your rental agreement again, the landlord may end your tenancy with a 14-day notice without giving you a chance to remedy it.</p>' end;
    v_extra := jsonb_build_object('Provision', coalesce(nullif(trim(d->>'provision'), ''), 'your lease and its rules'), 'Breach', trim(d->>'breach'), 'Cure', trim(d->>'cure'),
      'Repeat_Text', '[[REPEAT]]');

  elsif p_template = '2c-14-day' then
    v_reason := coalesce(d->>'reason', 'rent');
    if v_reason not in ('rent', 'breach') then raise exception 'Choose unpaid rent or a breach.'; end if;
    if r->>(case v_reason when 'rent' then 'nonpayment_14_day' else 'breach_14_day' end) = 'no' then
      raise exception '%', case when l.federal_program is not null and v_reason = 'rent' then 'This is a federally covered tenancy: unpaid rent needs the 30-day notice, not a 14-day notice.'
                                else 'A lease longer than one year can''t be ended with a 14-day notice. Use the 30-day notice.' end;
    end if;
    v_prior := coalesce(nullif(d->>'prior_notice_on', '')::date, notice_prior_within_year(l.id, v_reason, v_mail));
    if v_prior is not null and v_prior < v_mail - 365 then v_prior := null; end if;
    if not v_mm and v_prior is null then
      raise exception 'A lease of a year or less can only get a 14-day notice within a year of an earlier % notice. None is on file: send the 5-day notice instead, or enter the earlier notice''s date.',
        case v_reason when 'rent' then 'pay-or-vacate' else 'breach' end;
    end if;
    v_days := 14;
    v_deadline := notice_deadline(v_mail, 14);
    v_title := 'FOURTEEN-DAY NOTICE TO VACATE';
    v_statute := 'Wis. Stat. § 704.17' || case when v_mm then '(1p)' || case v_reason when 'rent' then '(a)' else '(b)' end else '(2)' || case v_reason when 'rent' then '(a)' else '(b)' end end;
    if v_reason = 'rent' then
      v_due := lease_rent_due(l.id, v_mail);
      if v_due <= 0 then raise exception 'This lease has no unpaid rent.'; end if;
      v_month := date_trunc('month', v_mail)::date;
      v_cur := least(v_due, greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id and kind = 'charge'
        and gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', entry_date) = v_month), 0));
      v_txt := 'You are in default in the payment of rent. Unpaid rent: <b>' || to_char(v_due, money_) || '</b> (' || to_char(v_month, 'FMMonth YYYY') || ': ' ||
        to_char(v_cur, money_) || '; earlier months: ' || to_char(v_due - v_cur, money_) || ').';
      v_short := 'Rent of ' || to_char(v_due, money_) || ' is unpaid.';
    else
      if length(trim(coalesce(d->>'breach', ''))) < 10 then raise exception 'Describe the breach: what happened, where and when.'; end if;
      v_txt := 'You have broken your rental agreement: ' || repair_esc(trim(d->>'breach'));
      v_short := 'It is for a violation of your rental agreement.';
    end if;
    v_extra := jsonb_build_object('Reason_Text', '[[REASON]]', 'Reason_Short', '[[SHORT]]',
      'Prior_Text', case when v_prior is null then '' else '[[PRIOR]]' end);

  elsif p_template = '2c-28-day' then
    if not v_mm then raise exception 'Only a month-to-month tenancy is ended with a 28-day notice. A lease for a term ends on its end date: use the Notice of Nonrenewal (Renewals page).'; end if;
    if l.federal_program is not null and length(trim(coalesce(d->>'reason', ''))) < 10 then
      raise exception 'Section 8 / federal tenancy: state the cause for ending it (the HAP contract requires good cause).';
    end if;
    -- First month-end that is at least 28 days after the notice is given (given day = day 1).
    v_end := (date_trunc('month', v_given + 27) + interval '1 month' - interval '1 day')::date;
    if nullif(d->>'end_on', '') is not null then
      if (d->>'end_on')::date < v_end then raise exception 'The tenancy can end no earlier than %.', to_char(v_end, 'FMMM/FMDD/YYYY'); end if;
      if (d->>'end_on')::date <> (date_trunc('month', (d->>'end_on')::date) + interval '1 month' - interval '1 day')::date then raise exception 'A month-to-month tenancy ends on the last day of a month.'; end if;
      v_end := (d->>'end_on')::date;
    end if;
    v_days := 28; v_deadline := v_end;
    v_title := '28-DAY NOTICE TERMINATING MONTH-TO-MONTH TENANCY';
    v_statute := 'Wis. Stat. § 704.19';
    v_extra := jsonb_build_object('Termination_Date', to_char(v_end, v_fmt),
      'Reason_Text', case when nullif(trim(d->>'reason'), '') is null then '' else '[[REASON]]' end);
    v_txt := case when nullif(trim(d->>'reason'), '') is null then '' else '<p>Reason: ' || repair_esc(trim(d->>'reason')) || '</p>' end;
  else
    raise exception 'Unknown notice %.', p_template;
  end if;

  v_extra := v_extra || jsonb_build_object('_keep_signature', true, 'Tenant_First_Name', '[[FIRST]]',
    'Notice_Title', v_title, 'Notice_Statute', v_statute, 'Notice_Days', v_days::text,
    'Notice_Date', to_char(v_mail, 'FMMonth FMDD, YYYY'), 'Mail_Date', to_char(v_mail, 'FMMonth FMDD, YYYY'),
    'Deadline', to_char(v_deadline, v_fmt), 'Service_Method', case v_service when 'personal' then 'personal delivery' else 'certified mail' end);
  v_html := letter_fill((select html from letter_templates where legacy_id = p_template), l.id, v_extra);
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where legacy_id = p_template;
  -- Parts built here from escaped values go in unescaped.
  v_html := replace(replace(replace(replace(v_html, '[[REPEAT]]', v_txt), '[[REASON]]', v_txt), '[[SHORT]]', v_short),
    '[[PRIOR]]', coalesce('<p>You were given a ' || case v_reason when 'rent' then 'notice for unpaid rent' else 'notice for breaking your rental agreement' end ||
      ' on ' || to_char(v_prior, 'FMMonth FMDD, YYYY') || ', less than one year ago.</p>', ''));
  v_email := replace(replace(v_email, '[[SHORT]]', v_short), '[[REASON]]', v_txt);

  return jsonb_build_object('template_id', (select id from letter_templates where legacy_id = p_template), 'template_name', (select name from letter_templates where legacy_id = p_template),
    'subject', case p_template when '2c-breach-cure' then case v_days when 5 then 'Five-Day' else 'Thirty-Day' end || ' Notice to Remedy Breach or Vacate'
      when '2c-14-day' then 'Fourteen-Day Notice to Vacate' else '28-Day Notice Terminating Tenancy' end, 'html', v_html, 'email_subject', v_subject, 'email_html', v_email,
    'days', v_days, 'deadline', v_deadline, 'prior_notice_on', v_prior, 'federal_program', l.federal_program, 'warning', v_warn);
end;
$$;
revoke all on function notice_build(text, uuid, date, jsonb, text) from public, anon, authenticated;

create or replace function notice_staff_build(p_template text, p_lease uuid, p_mail_on date, p_details jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_template = '2c-pay-or-vacate' and lease_rent_due(p_lease, coalesce(p_mail_on, current_date)) <= 0 then raise exception 'This lease has no unpaid rent.'; end if;
  return notice_build(p_template, p_lease, p_mail_on, p_details, auth.email());
end;
$$;
revoke all on function notice_staff_build(text, uuid, date, jsonb) from public, anon;
grant execute on function notice_staff_build(text, uuid, date, jsonb) to authenticated;
