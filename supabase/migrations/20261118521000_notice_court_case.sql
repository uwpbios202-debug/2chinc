-- After the eviction is eFiled (Stephen, 11/8/2026): staff record the court case on the notice (case number, filed on, return date
-- and time, where). The tenant is emailed once with the court date and a second pointer to free mediation (Mediate Milwaukee).
-- The office gets a reminder the day before the court date. Email only (ordinary message, not a legal notice); rent only, never late fees.

alter table public.notices add column if not exists case_number text;
alter table public.notices add column if not exists case_filed_on date;
alter table public.notices add column if not exists court_at timestamptz;
alter table public.notices add column if not exists court_place text;
alter table public.notices add column if not exists case_emailed_at timestamptz;
alter table public.notices add column if not exists court_reminded_at timestamptz;

create or replace function notice_record_case(p_id uuid, p_case text, p_filed_on date, p_court_at timestamptz, p_place text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n notices; v_to text[]; v_names text; v_unit text; v_due numeric; v_html text; v_when text; v_mailed boolean := false;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into n from notices where id = p_id for update;
  if n.id is null or n.lease_id is null then raise exception 'Notice not found'; end if;
  if nullif(trim(coalesce(p_case, '')), '') is null then raise exception 'Enter the case number'; end if;
  if p_filed_on is null then raise exception 'Enter the date the case was filed'; end if;
  if p_court_at is null then raise exception 'Enter the court (return) date and time'; end if;
  if p_court_at::date < p_filed_on then raise exception 'The court date cannot be before the filing date'; end if;
  update notices set case_number = trim(p_case), case_filed_on = p_filed_on, court_at = p_court_at, court_place = nullif(trim(coalesce(p_place, '')), ''),
         court_reminded_at = case when court_at is distinct from p_court_at then null else court_reminded_at end
   where id = p_id;

  if n.case_emailed_at is null then
    select array_agg(distinct lower(t.email)) filter (where coalesce(t.email, '') <> ''), string_agg(distinct split_part(trim(t.name), ' ', 1), ' and ')
      into v_to, v_names from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = n.lease_id;
    if coalesce(cardinality(n.emailed_to), 0) > 0 then v_to := n.emailed_to; end if;
    select ru.unit_number into v_unit from leases l left join rental_units ru on ru.id = l.unit_id where l.id = n.lease_id;
    v_due := lease_rent_due(n.lease_id, current_date);
    v_when := to_char(p_court_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY "at" FMHH12:MI AM');
    if coalesce(cardinality(v_to), 0) > 0 then
      v_html := '<p>Hi ' || replace(replace(replace(coalesce(v_names, 'there'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ',</p>'
        || '<p>An eviction case about Unit ' || coalesce(v_unit, '') || ' has been filed in Milwaukee County Circuit Court. '
        || 'Case number: <b>' || replace(replace(trim(p_case), '<', '&lt;'), '>', '&gt;') || '</b>.</p>'
        || '<p><b>Your court date: ' || v_when || '</b>'
        || case when nullif(trim(coalesce(p_place, '')), '') is not null then ', ' || replace(replace(trim(p_place), '<', '&lt;'), '>', '&gt;') else '' end
        || '. Please go. The court papers mailed to you have the official details.</p>'
        || '<p>It is not too late to settle this. Mediate Milwaukee offers <b>free</b> mediation between tenants and landlords:</p>'
        || '<ul><li>Apply online: <a href="https://mediatewisconsin.org/application-for-mediation-tenant/">https://mediatewisconsin.org/application-for-mediation-tenant/</a></li>'
        || '<li>Call: <b>(414) 939-8800</b>, Monday to Friday, 8:00 am to 4:00 pm</li>'
        || '<li>More information: <a href="https://mediatewisconsin.org/tenants/">https://mediatewisconsin.org/tenants/</a></li></ul>'
        || case when v_due > 0 then '<p>Unpaid rent today: <b>$' || to_char(v_due, 'FM999,990.00') || '</b>. You can pay from your bank in your resident portal: '
             || '<a href="https://2ndchinc.org/resident/#payments">https://2ndchinc.org/resident/#payments</a></p>' else '' end
        || '<p>Questions: reply to this email or call (262) 236-5443.</p><p>2nd Chance Housing</p>';
      insert into email_outbox (to_email, subject, html, kind)
      select x, 'Your court date, and free help to settle before it', v_html, 'notice_case_filed' from unnest(v_to) x;
      update notices set case_emailed_at = now() where id = p_id;
      v_mailed := true;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'tenant_emailed', v_mailed, 'court', v_when);
end;
$$;
revoke all on function notice_record_case(uuid, text, date, timestamptz, text) from public, anon;
grant execute on function notice_record_case(uuid, text, date, timestamptz, text) to authenticated;

-- Daily (same cron as the eFile reminder): the office is reminded the day before each court date.
create or replace function notice_court_reminders()
returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_tomorrow date := (now() at time zone 'America/Chicago')::date + 1; v_n int := 0; v_due numeric;
begin
  for r in
    select n.id, n.lease_id, n.case_number, n.court_at, n.court_place, n.template_name ~* 'pay rent or vacate' nonpay, ru.unit_number, ru.address, l.tenants_label
      from notices n join leases l on l.id = n.lease_id left join rental_units ru on ru.id = l.unit_id
     where n.status = 'sent' and not coalesce(n.voided, false) and n.court_at is not null and n.court_reminded_at is null
       and (n.court_at at time zone 'America/Chicago')::date = v_tomorrow
  loop
    v_due := lease_rent_due(r.lease_id, v_tomorrow - 1);
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org',
      'Court tomorrow: Unit ' || coalesce(r.unit_number, '?') || ', case ' || r.case_number,
      '<p><b>' || coalesce(r.tenants_label, '') || '</b>, ' || coalesce(r.address, '') || '.</p><p>Case <b>' || r.case_number || '</b>: '
        || to_char(r.court_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM') || coalesce(', ' || r.court_place, '') || '.</p>'
        || case when r.nonpay then '<p>Unpaid <b>rent</b> today: <b>$' || to_char(v_due, 'FM999,990.00') || '</b> (rent only: late fees are never part of the case).</p>' else '' end
        || '<p>Notices: <a href="https://2ndchinc.org/documents/notices/">https://2ndchinc.org/documents/notices/</a></p>', 'notice_court');
    update notices set court_reminded_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function notice_court_reminders() from public, anon, authenticated;
grant execute on function notice_court_reminders() to service_role;

create or replace function notices_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'sent_at', n.sent_at,
      'sent_by', n.sent_by, 'signed_by_agent', n.signed_by_agent, 'emailed_to', coalesce(n.emailed_to, '{}'), 'pdf_path', n.pdf_path, 'service_method', n.service_method,
      'served_on', n.served_on, 'service_note', n.service_note, 'voided', n.voided, 'status', n.status, 'batch', n.batch,
      'not_sent_reason', n.not_sent_reason, 'not_sent_at', n.not_sent_at, 'lease_label', u.address || ' — ' || l.tenants_label,
      'cure_deadline', case when n.lease_id is not null then n.cure_deadline end, 'efile_on', n.efile_on,
      'mediation_emailed_at', n.mediation_emailed_at, 'efile_reminded_at', n.efile_reminded_at,
      'rent_due', case when n.lease_id is not null and n.efile_on is not null then lease_rent_due(n.lease_id, current_date) end,
      'case_number', n.case_number, 'case_filed_on', n.case_filed_on, 'court_at', n.court_at, 'court_place', n.court_place,
      'case_emailed_at', n.case_emailed_at, 'court_reminded_at', n.court_reminded_at) order by coalesce(n.not_sent_at, n.sent_at) desc)
    from notices n left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id where n.status in ('sent', 'not_sent')), '[]'::jsonb);
end;
$$;
