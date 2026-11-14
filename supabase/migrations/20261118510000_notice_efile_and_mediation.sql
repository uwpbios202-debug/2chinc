-- Eviction timeline for lease notices (Stephen, 11/8/2026, after Unit 4's 5-day notice went by certified mail on 11/6).
--   Cure by  = the date service was recorded (certified-mail stamp date = day 1) + notice days - 1.
--   eFile on = the next court day after Cure by (weekends and court_holidays skipped).
-- Notice days: pay-or-vacate notices use lease_notice_rules (5, or 30 for federally covered / over-a-year leases);
-- other termination notices use the number of days in their name (e.g. "14-Day Notice to Vacate"). Notices with no day count
-- (12-hour repair notices) get no dates. Land contract notices keep their own cure_deadline and are not touched.
-- When service is recorded the tenant is emailed once about free mediation (Mediate Milwaukee). Email only: it is an ordinary
-- message, not the legal notice (CLAUDE.md). On the eFile date the office gets one email: file today / paid / partly paid,
-- with unpaid RENT only (late fees are never part of a filing).

alter table public.notices add column if not exists efile_on date;
alter table public.notices add column if not exists mediation_emailed_at timestamptz;
alter table public.notices add column if not exists efile_reminded_at timestamptz;

-- Next day the court is open after p_day.
create or replace function court_day_after(p_day date)
returns date
language plpgsql stable security definer set search_path = public as $$
declare d date := p_day + 1;
begin
  while extract(isodow from d) in (6, 7) or exists (select 1 from court_holidays h where h.day = d) loop
    d := d + 1;
  end loop;
  return d;
end;
$$;
revoke all on function court_day_after(date) from public, anon;
grant execute on function court_day_after(date) to authenticated, service_role;

-- How many days a lease notice gives, or null when it does not lead to an eviction filing.
create or replace function notice_days(p_id uuid)
returns int
language plpgsql stable security definer set search_path = public as $$
declare n notices; m text[];
begin
  select * into n from notices where id = p_id;
  if n.id is null or n.lease_id is null then return null; end if;
  if n.template_name ~* 'pay rent or vacate' then
    return (lease_notice_rules(n.lease_id)->>'nonpayment_days')::int;
  end if;
  if n.template_name ~* '(vacate|terminat)' then
    m := regexp_match(n.template_name, '([0-9]+)[- ]?day', 'i');
    if m is not null then return m[1]::int; end if;
  end if;
  return null;
end;
$$;
revoke all on function notice_days(uuid) from public, anon, authenticated;
grant execute on function notice_days(uuid) to service_role;

-- After service is recorded: work out Cure by / eFile on, and email the tenant about mediation once.
create or replace function notice_after_service(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n notices; v_days int; v_cure date; v_efile date; v_to text[]; v_names text; v_due numeric; v_html text; v_unit text;
begin
  select * into n from notices where id = p_id for update;
  if n.id is null or n.lease_id is null then return jsonb_build_object('ok', true, 'note', 'not a lease notice'); end if;
  v_days := notice_days(p_id);
  if n.served_on is null or v_days is null or coalesce(n.voided, false) or n.service_method = 'email_only' then
    update notices set efile_on = null, cure_deadline = case when v_days is null then cure_deadline end where id = p_id;
    return jsonb_build_object('ok', true, 'note', 'no eviction dates for this notice');
  end if;
  v_cure := n.served_on + v_days - 1;
  v_efile := court_day_after(v_cure);
  update notices set cure_deadline = v_cure, efile_on = v_efile where id = p_id;

  if n.mediation_emailed_at is null and n.status = 'sent' then
    select array_agg(distinct lower(t.email)) filter (where coalesce(t.email, '') <> ''),
           string_agg(distinct split_part(trim(t.name), ' ', 1), ' and ')
      into v_to, v_names
      from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = n.lease_id;
    if coalesce(cardinality(n.emailed_to), 0) > 0 then v_to := n.emailed_to; end if;
    select ru.unit_number into v_unit from leases l left join rental_units ru on ru.id = l.unit_id where l.id = n.lease_id;
    v_due := lease_rent_due(n.lease_id, current_date);
    if coalesce(cardinality(v_to), 0) > 0 then
      v_html := '<p>Hi ' || replace(replace(replace(coalesce(v_names, 'there'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ',</p>'
        || '<p>You were mailed a notice about '
        || case when v_due > 0 then '<b>$' || to_char(v_due, 'FM999,990.00') || '</b> of unpaid rent' else 'your tenancy' end
        || ' for Unit ' || coalesce(v_unit, '') || '. You can still settle this without going to court. Mediate Milwaukee offers <b>free</b> mediation '
        || 'between tenants and landlords, and it works best when it happens early.</p>'
        || '<ul><li>Apply online: <a href="https://mediatewisconsin.org/application-for-mediation-tenant/">https://mediatewisconsin.org/application-for-mediation-tenant/</a></li>'
        || '<li>Call: <b>(414) 939-8800</b>, Monday to Friday, 8:00 am to 4:00 pm</li>'
        || '<li>More information: <a href="https://mediatewisconsin.org/tenants/">https://mediatewisconsin.org/tenants/</a></li></ul>'
        || case when v_due > 0 then '<p>You can also pay the $' || to_char(v_due, 'FM999,990.00')
             || ' from your bank in your resident portal: <a href="https://2ndchinc.org/resident/#payments">https://2ndchinc.org/resident/#payments</a></p>' else '' end
        || '<p>Questions: reply to this email or call (262) 236-5443.</p><p>2nd Chance Housing</p>';
      insert into email_outbox (to_email, subject, html, kind)
      select x, 'Free help to resolve your rent before court', v_html, 'notice_mediation' from unnest(v_to) x;
      update notices set mediation_emailed_at = now() where id = p_id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'cure_by', v_cure, 'efile_on', v_efile, 'mediation_emailed', (select mediation_emailed_at is not null from notices where id = p_id));
end;
$$;
revoke all on function notice_after_service(uuid) from public, anon, authenticated;
grant execute on function notice_after_service(uuid) to service_role;

-- Recording service now also sets the dates and sends the mediation email.
create or replace function notice_record_service(p_id uuid, p_method text, p_served_on date, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update notices set service_method = p_method, served_on = p_served_on, service_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id;
  if not found then raise exception 'Notice not found'; end if;
  v := notice_after_service(p_id);
  return jsonb_build_object('ok', true) || v;
end;
$$;

-- Daily (cron notice-efile-reminder): one email to the office for each notice whose eFile date has come.
create or replace function notice_efile_reminders()
returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_today date := (now() at time zone 'America/Chicago')::date; v_due numeric; v_subject text; v_body text; v_n int := 0;
begin
  for r in
    select n.id, n.lease_id, n.template_name, n.served_on, n.cure_deadline, n.efile_on, ru.unit_number, ru.address, l.tenants_label,
           n.template_name ~* 'pay rent or vacate' as nonpay
      from notices n join leases l on l.id = n.lease_id left join rental_units ru on ru.id = l.unit_id
     where n.status = 'sent' and not coalesce(n.voided, false) and n.efile_reminded_at is null
       and n.efile_on is not null and n.efile_on <= v_today and n.efile_on >= v_today - 3
  loop
    v_due := lease_rent_due(r.lease_id, v_today);
    if r.nonpay and v_due <= 0 then
      v_subject := 'Unit ' || coalesce(r.unit_number, '?') || ': rent paid, do NOT file the eviction';
      v_body := '<p>The notice''s cure period ended ' || to_char(r.cure_deadline, 'FMMonth FMDD') || ' and the unpaid rent is now $0.00. Do not eFile.</p>';
    else
      v_subject := 'Unit ' || coalesce(r.unit_number, '?') || ': eviction can be eFiled today'
        || case when r.nonpay and exists (select 1 from lease_ledger_entries e where e.lease_id = r.lease_id and e.kind in ('payment', 'assistance')
                  and e.amount < 0 and e.entry_date >= r.served_on) then ' (partly paid since the notice: you decide)' else '' end;
      v_body := '<p><b>' || coalesce(r.tenants_label, '') || '</b>, ' || coalesce(r.address, '') || '.</p>'
        || '<p>' || r.template_name || ' served ' || to_char(r.served_on, 'FMMonth FMDD, YYYY') || ' (day 1). Cure period ended '
        || to_char(r.cure_deadline, 'FMDay, FMMonth FMDD') || '. Earliest eFile: <b>' || to_char(r.efile_on, 'FMDay, FMMonth FMDD, YYYY') || '</b>.</p>'
        || case when r.nonpay then '<p>Unpaid <b>rent</b> today: <b>$' || to_char(v_due, 'FM999,990.00') || '</b> (rent only: late fees are never part of the filing).</p>' else '' end
        || '<p>Notices: <a href="https://2ndchinc.org/documents/notices/">https://2ndchinc.org/documents/notices/</a></p>';
    end if;
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', v_subject, v_body, 'notice_efile');
    update notices set efile_reminded_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function notice_efile_reminders() from public, anon, authenticated;
grant execute on function notice_efile_reminders() to service_role;

-- The notices page shows the new dates.
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
      'rent_due', case when n.lease_id is not null and n.efile_on is not null then lease_rent_due(n.lease_id, current_date) end) order by coalesce(n.not_sent_at, n.sent_at) desc)
    from notices n left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id where n.status in ('sent', 'not_sent')), '[]'::jsonb);
end;
$$;
