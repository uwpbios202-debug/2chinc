-- Smoke alarm checks (Stephen, 11/5/2026).
--
-- Every alarm in 6622 and 6626 N Bourbon St is a row in alarm_points (building, where it is, a reference photo).
-- Between the 1st and the 5th of each month someone visits, presses each alarm's test button and ticks what they
-- found (check boxes, alarm_checks.findings). Office staff and field staff both enter checks at
-- https://2ndchinc.org/staff/alarms/ ; a check that needs attention emails the office.
--
-- Reports: office staff send a report to anyone who asks (alarm_reports). A person's first report covers every check
-- since the checks began; each later report to the same email starts where their last report ended.
-- Locked like the rest of the schema: RLS on, no policies, everything through the functions below.

create table if not exists alarm_points (
  id uuid primary key default gen_random_uuid(),
  building text not null check (building in ('6622', '6626')),
  name text not null,                     -- e.g. "Alarm 3"
  location text,                          -- e.g. "Basement, by the furnace"
  kind text not null default 'smoke' check (kind in ('smoke', 'smoke_co', 'co', 'heat')),
  photo_path text,                        -- reference photo in the alarm-photos bucket, so the checker finds the right one
  sort int not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists alarm_checks (
  id bigint generated always as identity primary key,
  alarm_id uuid not null references alarm_points(id) on delete cascade,
  checked_at timestamptz not null default now(),
  check_month date not null,              -- first day of the month (Central time) the check counts for
  findings text[] not null,               -- codes, see alarm_finding_label()
  status text not null check (status in ('ok', 'fixed', 'attention')),
  notes text,
  photo_path text,
  checked_by text not null
);
create index if not exists alarm_checks_alarm_month on alarm_checks (alarm_id, check_month);
create index if not exists alarm_checks_at on alarm_checks (checked_at);

create table if not exists alarm_reports (
  id bigint generated always as identity primary key,
  recipient_name text not null,
  recipient_email text not null,
  organization text,
  period_from timestamptz not null,
  period_to timestamptz not null,
  checks_count int not null default 0,
  sent_by text not null,
  sent_at timestamptz not null default now(),
  outbox_id bigint
);
create index if not exists alarm_reports_email on alarm_reports (lower(recipient_email), period_to desc);

alter table alarm_points enable row level security;
alter table alarm_checks enable row level security;
alter table alarm_reports enable row level security;

-- New tables need explicit grants (Supabase change, 10/30/2026). The portals reach these only through the functions below.
grant all on table alarm_points, alarm_checks, alarm_reports to service_role;

-- ---------------------------------------------------------------------------
-- Who may do what

-- Enter checks, edit alarms, add photos: office staff and active field staff, with the authenticator code.
create or replace function alarm_can_check()
returns boolean
language sql stable security definer set search_path = public as $$
  select condo_session_ok() and (condo_is_staff() or field_is_staff());
$$;
revoke all on function alarm_can_check() from public, anon;
grant execute on function alarm_can_check() to authenticated;

-- ---------------------------------------------------------------------------
-- The check boxes. Order and wording here are what the report shows; the staff page uses the same codes.

create or replace function alarm_finding_label(p_code text)
returns text
language sql immutable as $$
  select case p_code
    when 'sounded'          then 'Sounded when tested'
    when 'weak'             then 'Sound was weak or quiet'
    when 'no_sound'         then 'Did not sound'
    when 'no_access'        then 'Could not get to it'
    when 'chirping'         then 'Chirping (low battery)'
    when 'dusty'            then 'Dusty or dirty'
    when 'damaged'          then 'Damaged or cracked'
    when 'missing'          then 'Missing or taken down'
    when 'covered'          then 'Covered, painted over or blocked'
    when 'disconnected'     then 'Battery taken out or unplugged'
    when 'expired'          then 'Past its replace-by date'
    when 'battery_replaced' then 'Put in a new battery'
    when 'cleaned'          then 'Cleaned it'
    when 'reattached'       then 'Put it back up or reconnected it'
    when 'replaced'         then 'Replaced the alarm'
    when 'needs_repair'     then 'Needs a repair (office told)'
  end;
$$;

-- ok: it sounded and nothing was wrong. fixed: something was wrong, it was fixed on the spot, and it sounded.
-- attention: it did not sound, could not be reached, or a problem is left.
create or replace function alarm_status(p_f text[])
returns text
language sql immutable as $$
  select case
    when not ('sounded' = any (p_f)) or 'needs_repair' = any (p_f) then 'attention'
    when p_f && array['weak', 'no_sound', 'chirping', 'dusty', 'damaged', 'missing', 'covered', 'disconnected', 'expired']
      then case when p_f && array['battery_replaced', 'cleaned', 'reattached', 'replaced'] then 'fixed' else 'attention' end
    else 'ok' end;
$$;

-- ---------------------------------------------------------------------------
-- Staff page data

create or replace function alarm_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_month date := date_trunc('month', now() at time zone 'America/Chicago')::date;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'office', condo_is_staff(),
    'month', v_month,
    'today', (now() at time zone 'America/Chicago')::date,
    'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'building', p.building, 'name', p.name, 'location', p.location,
        'kind', p.kind, 'photo_path', p.photo_path, 'sort', p.sort, 'active', p.active,
        'this_month', (select jsonb_build_object('id', c.id, 'at', c.checked_at, 'status', c.status, 'findings', c.findings, 'notes', c.notes, 'by', c.checked_by, 'photo_path', c.photo_path)
                        from alarm_checks c where c.alarm_id = p.id and c.check_month = v_month order by c.checked_at desc limit 1),
        'last', (select jsonb_build_object('at', c.checked_at, 'status', c.status) from alarm_checks c where c.alarm_id = p.id order by c.checked_at desc limit 1))
        order by p.building, p.sort, p.name) from alarm_points p), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x) from (
        select c.id, c.checked_at as at, c.status, c.findings, c.notes, c.checked_by as by, c.photo_path, p.building, p.name, p.location
          from alarm_checks c join alarm_points p on p.id = c.alarm_id order by c.checked_at desc limit 60) x), '[]'::jsonb),
    'reports', case when condo_is_staff() then coalesce((select jsonb_agg(x) from (
        select r.id, r.recipient_name, r.recipient_email, r.organization, r.period_from, r.period_to, r.checks_count, r.sent_by, r.sent_at
          from alarm_reports r order by r.sent_at desc limit 30) x), '[]'::jsonb) else '[]'::jsonb end);
end;
$$;
revoke all on function alarm_staff_list() from public, anon;
grant execute on function alarm_staff_list() to authenticated;

-- Record one check. A check that needs attention emails the office (info@).
create or replace function alarm_check_save(p_alarm uuid, p_findings text[], p_notes text, p_photo text)
returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare
  v_f text[]; v_status text; v_id bigint; p alarm_points;
  v_month date := date_trunc('month', now() at time zone 'America/Chicago')::date;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into p from alarm_points where id = p_alarm and active;
  if not found then raise exception 'Alarm not found.'; end if;
  select coalesce(array_agg(distinct f), '{}') into v_f from unnest(coalesce(p_findings, '{}')) f;
  if exists (select 1 from unnest(v_f) f where alarm_finding_label(f) is null) then raise exception 'Unknown check box.'; end if;
  if not (v_f && array['sounded', 'no_sound', 'no_access']) then
    raise exception 'Tick what happened when you pressed the test button: Sounded, Did not sound, or Could not get to it.';
  end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'Notes are too long (1,000 characters at most).'; end if;
  v_status := alarm_status(v_f);
  insert into alarm_checks (alarm_id, check_month, findings, status, notes, photo_path, checked_by)
  values (p_alarm, v_month, v_f, v_status, nullif(trim(p_notes), ''), nullif(trim(p_photo), ''), auth.email())
  returning id into v_id;
  if v_status = 'attention' then
    insert into email_outbox (to_email, subject, html, kind) values (
      'info@2ndchinc.org',
      'Smoke alarm needs attention: ' || p.building || ' N Bourbon St, ' || p.name,
      '<p>A smoke alarm check found a problem that is not fixed yet.</p><ul>'
        || '<li><b>Alarm:</b> ' || repair_esc(p.building) || ' N Bourbon St, ' || repair_esc(p.name) || coalesce(' (' || repair_esc(p.location) || ')', '') || '</li>'
        || '<li><b>Found:</b> ' || repair_esc((select string_agg(alarm_finding_label(f), ', ') from unnest(v_f) f)) || '</li>'
        || coalesce('<li><b>Notes:</b> ' || repair_esc(nullif(trim(p_notes), '')) || '</li>', '')
        || '<li><b>Checked by:</b> ' || repair_esc(auth.email()) || '</li></ul>'
        || '<p>Open the alarms page: https://2ndchinc.org/staff/alarms/</p>',
      'alarm_attention');
  end if;
  return v_id;
end;
$$;
revoke all on function alarm_check_save(uuid, text[], text, text) from public, anon;
grant execute on function alarm_check_save(uuid, text[], text, text) to authenticated;

-- Add an alarm (p_id null) or change one: where it is, its name, kind, reference photo, retired or not.
create or replace function alarm_point_save(p_id uuid, p_building text, p_name text, p_location text, p_kind text, p_active boolean, p_photo text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 1 then raise exception 'Give the alarm a name, like "Alarm 8".'; end if;
  if p_id is null then
    if p_building not in ('6622', '6626') then raise exception 'Choose the building.'; end if;
    insert into alarm_points (building, name, location, kind, photo_path, sort)
    values (p_building, trim(p_name), nullif(trim(p_location), ''), coalesce(nullif(p_kind, ''), 'smoke'), nullif(trim(p_photo), ''),
            coalesce((select max(sort) + 10 from alarm_points where building = p_building), 10))
    returning id into v_id;
  else
    update alarm_points set name = trim(p_name), location = nullif(trim(p_location), ''), kind = coalesce(nullif(p_kind, ''), kind),
           active = coalesce(p_active, active), photo_path = coalesce(nullif(trim(p_photo), ''), photo_path)
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Alarm not found.'; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function alarm_point_save(uuid, text, text, text, text, boolean, text) from public, anon;
grant execute on function alarm_point_save(uuid, text, text, text, text, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Reports

-- The period a report to this email would cover: from the end of their last report, or (first report) from the first check ever.
create or replace function alarm_report_from(p_email text)
returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select max(period_to) from alarm_reports where lower(recipient_email) = lower(trim(p_email))),
    (select min(checked_at) - interval '1 second' from alarm_checks),
    now());
$$;
revoke all on function alarm_report_from(text) from public, anon;

-- The report itself (email-safe HTML, inline styles). Checks in (p_from, p_to].
create or replace function alarm_report_html(p_from timestamptz, p_to timestamptz, p_name text, p_org text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_html text; v_months date[]; v_b text; v_rows text; v_n int; v_att int; v_fixed int; v_ok int; v_missed int;
  fmt constant text := 'FMMM/FMDD/YYYY';
  tz constant text := 'America/Chicago';
begin
  -- Months shown: every month whose 1st-5th check window falls in the period, plus any month with a check in it.
  select coalesce(array_agg(m order by m), '{}') into v_months from (
    select distinct m from (
      select g::date m from generate_series(date_trunc('month', p_from at time zone tz), date_trunc('month', p_to at time zone tz), interval '1 month') g
       where (g::timestamp + interval '5 days') at time zone tz > p_from and g::timestamp at time zone tz <= p_to
      union
      select c.check_month from alarm_checks c where c.checked_at > p_from and c.checked_at <= p_to) s) t;

  select count(*), count(*) filter (where status = 'attention'), count(*) filter (where status = 'fixed'), count(*) filter (where status = 'ok')
    into v_n, v_att, v_fixed, v_ok from alarm_checks where checked_at > p_from and checked_at <= p_to;

  -- Alarm-months with no check (only alarms that existed by the end of that month's window).
  select count(*) into v_missed from alarm_points p cross join unnest(v_months) m
   where (p.active or exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.checked_at > p_from and c.checked_at <= p_to))
     and p.created_at <= (m::timestamp + interval '1 month') at time zone tz
     and not exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.check_month = m and c.checked_at > p_from and c.checked_at <= p_to);

  v_html := '<div style="font:15px/1.45 Arial,Helvetica,sans-serif;color:#1d2433;max-width:900px">'
    || '<h2 style="margin:0 0 4px">Smoke alarm check report</h2>'
    || '<div style="color:#555">6622 and 6626 N Bourbon St, Milwaukee, WI 53224 · 2nd Chance Housing Inc.</div>'
    || '<p style="margin:12px 0"><b>Period:</b> ' || to_char(p_from at time zone tz, fmt) || ' to ' || to_char(p_to at time zone tz, fmt)
    || coalesce('<br><b>Prepared for:</b> ' || repair_esc(nullif(trim(p_name), '')) || coalesce(', ' || repair_esc(nullif(trim(p_org), '')), ''), '')
    || '<br><b>How we check:</b> between the 1st and the 5th of every month, a staff member presses the test button on each alarm and records what they found.</p>';

  if v_n = 0 then
    v_html := v_html || '<p><b>No checks were recorded in this period.</b></p>';
  else
    v_html := v_html || '<p><b>Summary:</b> ' || v_n || ' check' || case when v_n = 1 then '' else 's' end || ' over '
      || cardinality(v_months) || ' month' || case when cardinality(v_months) = 1 then '' else 's' end || '. '
      || v_ok || ' worked with nothing wrong; ' || v_fixed || ' had a problem fixed on the spot; ' || v_att || ' needed more work'
      || case when v_missed > 0 then '; ' || v_missed || ' alarm-month' || case when v_missed = 1 then '' else 's' end || ' not checked' else '' end || '.</p>';

    foreach v_b in array array['6622', '6626'] loop
      select string_agg(
          '<tr><td style="padding:5px 8px;border-bottom:1px solid #ddd"><b>' || repair_esc(p.name) || '</b>'
          || coalesce('<br><span style="color:#666;font-size:13px">' || repair_esc(p.location) || '</span>', '') || '</td>'
          || (select string_agg(
                coalesce((select '<td style="padding:5px 8px;border-bottom:1px solid #ddd;text-align:center;white-space:nowrap;'
                    || case c.status when 'ok' then 'color:#1a7f37">✓ OK' when 'fixed' then 'color:#0b5cad">✓ Fixed' else 'color:#b42318;font-weight:bold">⚠ Needs work' end
                    || '<br><span style="color:#666;font-size:12px">' || to_char(c.checked_at at time zone tz, 'FMMM/FMDD') || '</span></td>'
                  from alarm_checks c where c.alarm_id = p.id and c.check_month = m and c.checked_at > p_from and c.checked_at <= p_to
                  order by c.checked_at desc limit 1),
                case when p.created_at > (m::timestamp + interval '1 month') at time zone tz
                  then '<td style="padding:5px 8px;border-bottom:1px solid #ddd;text-align:center;color:#999">n/a</td>'
                  else '<td style="padding:5px 8px;border-bottom:1px solid #ddd;text-align:center;color:#b42318">not checked</td>' end), '' order by m)
              from unnest(v_months) m)
          || '</tr>', '' order by p.sort, p.name)
        into v_rows
        from alarm_points p
       where p.building = v_b
         and (p.active or exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.checked_at > p_from and c.checked_at <= p_to));
      if v_rows is not null then
        v_html := v_html || '<h3 style="margin:18px 0 6px">' || v_b || ' N Bourbon St</h3>'
          || '<table style="border-collapse:collapse;font-size:14px;width:100%"><tr><th style="text-align:left;padding:5px 8px;border-bottom:2px solid #999">Alarm</th>'
          || (select string_agg('<th style="padding:5px 8px;border-bottom:2px solid #999">' || to_char(m, 'Mon YYYY') || '</th>', '' order by m) from unnest(v_months) m)
          || '</tr>' || v_rows || '</table>';
      end if;
    end loop;

    -- Every check that found something, with what was found and done.
    select string_agg('<tr><td style="padding:5px 8px;border-bottom:1px solid #ddd;white-space:nowrap">' || to_char(c.checked_at at time zone tz, fmt) || '</td>'
        || '<td style="padding:5px 8px;border-bottom:1px solid #ddd">' || p.building || ' · ' || repair_esc(p.name) || '</td>'
        || '<td style="padding:5px 8px;border-bottom:1px solid #ddd">' || repair_esc((select string_agg(alarm_finding_label(f), ', ') from unnest(c.findings) f))
        || coalesce('<br><i>' || repair_esc(c.notes) || '</i>', '') || '</td>'
        || '<td style="padding:5px 8px;border-bottom:1px solid #ddd;white-space:nowrap">' || case c.status when 'fixed' then 'Fixed' else '<b style="color:#b42318">Needs work</b>' end || '</td></tr>',
        '' order by c.checked_at)
      into v_rows
      from alarm_checks c join alarm_points p on p.id = c.alarm_id
     where c.checked_at > p_from and c.checked_at <= p_to and c.status <> 'ok';
    if v_rows is not null then
      v_html := v_html || '<h3 style="margin:18px 0 6px">Problems found and what was done</h3>'
        || '<table style="border-collapse:collapse;font-size:14px;width:100%"><tr><th style="text-align:left;padding:5px 8px;border-bottom:2px solid #999">Date</th>'
        || '<th style="text-align:left;padding:5px 8px;border-bottom:2px solid #999">Alarm</th><th style="text-align:left;padding:5px 8px;border-bottom:2px solid #999">Found / done</th>'
        || '<th style="text-align:left;padding:5px 8px;border-bottom:2px solid #999">Result</th></tr>' || v_rows || '</table>';
    end if;
  end if;

  return v_html || '<p style="color:#555;margin-top:18px">Questions: reply to this email, or write to info@2ndchinc.org.<br>2nd Chance Housing Inc., 6626 N Bourbon St, Milwaukee, WI 53224</p></div>';
end;
$$;
revoke all on function alarm_report_html(timestamptz, timestamptz, text, text) from public, anon;

-- Office staff: preview what a report to this email would cover (p_from overrides the start date).
create or replace function alarm_report_preview(p_email text, p_name text, p_org text, p_from date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz := now(); v_last timestamptz;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  select max(period_to) into v_last from alarm_reports where lower(recipient_email) = lower(trim(p_email));
  v_from := case when p_from is not null then (p_from::timestamp at time zone 'America/Chicago') else alarm_report_from(p_email) end;
  return jsonb_build_object('from', v_from, 'to', v_to, 'last_report', v_last,
    'checks', (select count(*) from alarm_checks where checked_at > v_from and checked_at <= v_to),
    'html', alarm_report_html(v_from, v_to, p_name, p_org));
end;
$$;
revoke all on function alarm_report_preview(text, text, text, date) from public, anon;
grant execute on function alarm_report_preview(text, text, text, date) to authenticated;

-- Office staff: email the report and remember it, so this person's next report starts where this one ends.
create or replace function alarm_report_send(p_email text, p_name text, p_org text, p_from date)
returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz := now(); v_out bigint; v_id bigint; v_n int; v_email text := lower(trim(p_email));
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the email address the report goes to.'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Enter the name of the person who asked.'; end if;
  v_from := case when p_from is not null then (p_from::timestamp at time zone 'America/Chicago') else alarm_report_from(v_email) end;
  select count(*) into v_n from alarm_checks where checked_at > v_from and checked_at <= v_to;
  insert into email_outbox (to_email, subject, html, kind) values (v_email,
    'Smoke alarm check report: 6622 and 6626 N Bourbon St (' || to_char(v_from at time zone 'America/Chicago', 'FMMM/FMDD/YYYY') || ' to ' || to_char(v_to at time zone 'America/Chicago', 'FMMM/FMDD/YYYY') || ')',
    '<p>Dear ' || repair_esc(trim(p_name)) || ',</p><p>Here is the smoke alarm check report you asked for.</p>' || alarm_report_html(v_from, v_to, p_name, p_org),
    'alarm_report') returning id into v_out;
  insert into alarm_reports (recipient_name, recipient_email, organization, period_from, period_to, checks_count, sent_by, outbox_id)
  values (trim(p_name), v_email, nullif(trim(p_org), ''), v_from, v_to, v_n, auth.email(), v_out) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function alarm_report_send(text, text, text, date) from public, anon;
grant execute on function alarm_report_send(text, text, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Photos (private bucket). Staff and field staff upload and read; nobody else.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('alarm-photos', 'alarm-photos', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do nothing;

drop policy if exists "alarm-photos upload" on storage.objects;
create policy "alarm-photos upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'alarm-photos' and alarm_can_check());
drop policy if exists "alarm-photos read" on storage.objects;
create policy "alarm-photos read" on storage.objects for select to authenticated
  using (bucket_id = 'alarm-photos' and alarm_can_check());

-- ---------------------------------------------------------------------------
-- The 14 alarms photographed on 11/5/2026 (7 per building). Their locations are filled in on the staff page;
-- the reference photos are uploaded separately.
insert into alarm_points (building, name, sort)
select b, 'Alarm ' || n, n * 10
  from (values ('6622'), ('6626')) v(b) cross join generate_series(1, 7) n
 where not exists (select 1 from alarm_points);
