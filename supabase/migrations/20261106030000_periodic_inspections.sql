-- Periodic inspections (Stephen, 10/7/2026: "we drop nothing but strengthen"). Adds to the field-staff unit
-- inspections (20261102000000) and the due list (20261105130000); move-in and move-out are unchanged.
--   * Every inspection has a purpose: routine | annual | pre_move_out | follow_up | complaint | other.
--     Existing rows become 'routine'. Only routine and annual inspections restart a unit's clock.
--   * inspection_schedules: per-unit frequency (months), an optional next-due override, the assigned inspector,
--     paused or not. Units without a row keep the global portal_settings.inspection_interval_days.
--   * inspection_appointments: a date and time window for one unit. For an occupied unit the office sends the
--     Wisconsin 12-hour notice to enter (ATCP 134.09(2)(a); Wis. Stat. § 704.05(2)) through the existing
--     notices function (PDF on letterhead, filed in the resident portal under Documents > Notices, emailed to
--     each tenant) — or records that the tenant agreed to the entry. Tenants see upcoming appointments.
--   * Submitting an inspection marks its appointment done and rolls the unit's next due date forward.
--   * inspections_digest(): an email to the office listing overdue units, units due within 30 days and the
--     next 14 days of appointments. Staff send it from the schedule page (no cron).

alter table inspections add column if not exists purpose text not null default 'routine';
do $$ begin
  alter table inspections add constraint inspections_purpose_chk
    check (purpose in ('routine', 'annual', 'pre_move_out', 'follow_up', 'complaint', 'other'));
exception when duplicate_object then null; end $$;

create or replace function inspection_purpose_label(p text)
returns text language sql immutable as $$
  select case p when 'routine' then 'Routine inspection' when 'annual' then 'Annual inspection'
    when 'pre_move_out' then 'Pre-move-out inspection' when 'follow_up' then 'Follow-up inspection'
    when 'complaint' then 'Inspection about a complaint' when 'other' then 'Inspection' else coalesce(p, 'Inspection') end;
$$;

create table if not exists inspection_schedules (
  property_id text not null,
  unit text not null,
  frequency_months int not null default 12 check (frequency_months between 1 and 60),
  next_due date,                      -- set by hand or rolled forward on each routine/annual inspection
  inspector_email text,               -- usual inspector (field_staff or office staff); optional
  active boolean not null default true,   -- false = paused (e.g. owner-managed unit)
  note text,
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (property_id, unit)
);
alter table inspection_schedules enable row level security;

create table if not exists inspection_appointments (
  id uuid primary key default gen_random_uuid(),
  property_id text not null,
  unit text not null,
  lease_id uuid references leases(id),        -- the active lease when scheduled (null = vacant)
  purpose text not null default 'routine' check (purpose in ('routine', 'annual', 'pre_move_out', 'follow_up', 'complaint', 'other')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  inspector_email text,
  status text not null default 'scheduled' check (status in ('scheduled', 'done', 'cancelled')),
  entry_basis text check (entry_basis in ('notice', 'consent', 'vacant')),
  consent_note text,                          -- how/when the tenant agreed, when no notice was sent
  note text,                                  -- shown to the tenant
  notice_id uuid references notices(id),
  notice_sent_at timestamptz,
  inspection_id uuid references inspections(id),
  created_by text,
  created_at timestamptz not null default now(),
  cancelled_reason text,
  cancelled_at timestamptz,
  check (ends_at > starts_at)
);
create index if not exists inspection_appts_unit_idx on inspection_appointments (property_id, unit, starts_at);
create index if not exists inspection_appts_when_idx on inspection_appointments (status, starts_at);
alter table inspection_appointments enable row level security;
alter table inspections add column if not exists appointment_id uuid references inspection_appointments(id);

-- The property id ('6626-n-bourbon') for a rental unit, same rule as inspections_due.
create or replace function inspection_pid_for(p_address text)
returns text language sql immutable as $$
  select case split_part(coalesce(p_address, ''), ' ', 1) when '6626' then '6626-n-bourbon' when '6622' then '6622-n-bourbon' end;
$$;

create or replace function inspection_active_lease(p_property text, p_unit text)
returns uuid language sql stable security definer set search_path = public as $$
  select l.id from leases l where l.unit_id = inspection_rental_unit(p_property, p_unit) and l.status = 'active'
  order by l.start_date desc nulls last limit 1;
$$;
revoke all on function inspection_active_lease(text, text) from public, anon, authenticated;

create or replace function inspection_window_text(p_start timestamptz, p_end timestamptz)
returns text language sql immutable as $$
  select to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD') || ', between '
    || to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM');
$$;

create or replace function inspection_appt_row(a inspection_appointments)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('purpose_label', inspection_purpose_label(a.purpose), 'window', inspection_window_text(a.starts_at, a.ends_at),
    'address', (select ru.address from rental_units ru where ru.id = inspection_rental_unit(a.property_id, a.unit)),
    'tenants', (select l.tenants_label from leases l where l.id = a.lease_id),
    'notice_pdf', (select n.pdf_path from notices n where n.id = a.notice_id));
$$;
revoke all on function inspection_appt_row(inspection_appointments) from public, anon, authenticated;

-- 12-hour notice for an inspection (same wording as the repair notice, without a request number).
insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values
('2c-12-hour-inspection', 'Tenant', '2nd Chance — 12 Hour Notice (Inspection)', 'Notice To Enter',
 'Made from the inspection schedule when staff book an inspection of an occupied unit: the 12-hour notice to enter.',
 '<p style="text-align: center"><strong>12 HOUR NOTICE</strong></p>
<p style="text-align: center">Wisconsin Statute § 704.05(2) · ATCP 134.09(2)(a)1.</p>
<p>[[Unit_Address]]</p>
<p>To: [[Lease_All_Tenants]]</p>
<p>Date: [[Current_Date]]     Time: [[Notice_Time]]</p>
<p><strong>This is a 12-hour notice as required by law.</strong></p>
<p>We will be entering your rental unit at least 12 hours after the date and time above. Our entry will be at any time between [[Entry_Window]] on [[Entry_Date]]. The purpose of our entry is: [[Entry_Purpose]].</p>
<p><strong>NOTE:</strong></p>
<p>Tenants don''t have any rights to deny the landlord entry if the landlord has given proper notice.</p>
<p>Tenants cannot require that the tenant be there during the time that the landlord has chosen to enter. A tenant isn''t allowed to say, "I have to be here in order for you to come in." If the tenant happens to be there during the time that the landlord has chosen to enter, it''s perfectly allowable under these laws for the tenant to stay.</p>
<p>A landlord cannot require that a tenant NOT be there during the time that the landlord has chosen to enter. Similar to the above point, a landlord doesn''t have the right to tell the tenant that they may not be in their home during the landlord''s entry.</p>
<p>If you have any questions or concerns, or agree to us entering the unit at an earlier time, please contact us at [[Org_Phone]].</p>
<p>[[Sender_Signature]]</p>',
 array['Unit_Address', 'Lease_All_Tenants', 'Current_Date', 'Notice_Time', 'Entry_Window', 'Entry_Date', 'Entry_Purpose', 'Org_Phone', 'Sender_Signature'])
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name;

-- ---------------------------------------------------------------------------
-- Due list: same output as before (consumers: /staff/, /staff/unit/, /inspections/review/), now honoring each
-- unit's schedule. Extra fields: frequency_months, scheduled (custom schedule), paused, inspector, next_appt.
create or replace function inspections_due()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_days int := coalesce(nullif((select value from portal_settings where key = 'inspection_interval_days'), '')::int, 180); v_all boolean;
begin
  if auth.uid() is null or not (condo_is_staff() or field_is_staff()) then raise exception 'Staff sign-in required' using errcode = '42501'; end if;
  v_all := condo_is_staff();
  return jsonb_build_object('interval_days', v_days, 'units', coalesce((select jsonb_agg(x order by (x ->> 'sort')::int, x ->> 'due_on' nulls first, x ->> 'unit') from (
    select jsonb_build_object('property_id', ru.pid, 'unit', ru.unit_number, 'address', ru.address,
        'occupied', exists (select 1 from leases l where l.unit_id = ru.id and l.status = 'active'),
        'last', d.last_done, 'due_on', due.d,
        'state', case when coalesce(s.active, true) = false then 'ok' when due.d is null then 'never' when due.d < current_date then 'overdue' when due.d <= current_date + 30 then 'soon' else 'ok' end,
        'sort', case when coalesce(s.active, true) = false then 4 when due.d is null then 0 when due.d < current_date then 1 when due.d <= current_date + 30 then 2 else 3 end,
        'frequency_months', s.frequency_months, 'scheduled', s.property_id is not null, 'paused', coalesce(s.active, true) = false,
        'inspector', s.inspector_email, 'schedule_note', s.note,
        'next_appt', (select jsonb_build_object('id', a.id, 'starts_at', a.starts_at, 'ends_at', a.ends_at, 'purpose', a.purpose)
                      from inspection_appointments a where a.property_id = ru.pid and a.unit = ru.unit_number and a.status = 'scheduled'
                      order by a.starts_at limit 1)) x
    from (select ru.*, inspection_pid_for(ru.address) pid from rental_units ru where ru.unit_number is not null) ru
    left join inspection_schedules s on s.property_id = ru.pid and s.unit = ru.unit_number
    left join lateral (select max(i.inspected_on) last_done from inspections i where i.property_id = ru.pid and i.unit = ru.unit_number
                       and i.status = 'submitted' and i.purpose in ('routine', 'annual')) d on true
    cross join lateral (select coalesce(s.next_due, case when d.last_done is null then null
                          when s.property_id is not null then (d.last_done + make_interval(months => s.frequency_months))::date
                          else d.last_done + v_days end) d) due
    where ru.pid is not null and (v_all or exists (select 1 from staff_units su where lower(su.email) = lower(auth.email()) and su.property_id = ru.pid and su.unit = ru.unit_number))) q), '[]'::jsonb));
end;
$$;
revoke all on function inspections_due() from public, anon;
grant execute on function inspections_due() to authenticated;

-- ---------------------------------------------------------------------------
-- Saving an inspection: as before, plus purpose and appointment. The old 6-argument version is replaced by one
-- with two optional arguments, so existing calls keep working.
drop function if exists field_save_inspection(uuid, text, text, date, jsonb, boolean);
create or replace function field_save_inspection(p_id uuid, p_property text, p_unit text, p_date date, p_data jsonb, p_submit boolean default false,
  p_purpose text default null, p_appointment uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r inspections; v_req int := 0; v_purpose text; v_appt uuid; s inspection_schedules;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  if p_purpose is not null and p_purpose not in ('routine', 'annual', 'pre_move_out', 'follow_up', 'complaint', 'other') then raise exception 'Unknown inspection purpose'; end if;
  select * into r from inspections where id = p_id;
  if found and (r.property_id <> p_property or r.unit <> p_unit) then raise exception 'Wrong unit' using errcode = '42501'; end if;
  if found and r.status = 'submitted' then raise exception 'This inspection was already submitted' using errcode = '42501'; end if;
  if p_appointment is not null and not exists (select 1 from inspection_appointments a where a.id = p_appointment and a.property_id = p_property and a.unit = p_unit) then
    raise exception 'That appointment is for another unit'; end if;
  v_appt := coalesce(p_appointment, r.appointment_id);
  v_purpose := coalesce(p_purpose, r.purpose, (select a.purpose from inspection_appointments a where a.id = v_appt), 'routine');
  insert into inspections (id, property_id, unit, inspector_email, inspected_on, data, status, submitted_at, purpose, appointment_id)
  values (p_id, p_property, p_unit, lower(auth.email()), coalesce(p_date, current_date), coalesce(p_data, '{}'::jsonb),
          case when p_submit then 'submitted' else 'draft' end, case when p_submit then now() end, v_purpose, v_appt)
  on conflict (id) do update set
    inspected_on = coalesce(p_date, inspections.inspected_on),
    data = coalesce(p_data, inspections.data),
    status = case when p_submit then 'submitted' else 'draft' end,
    submitted_at = case when p_submit then now() else null end,
    purpose = v_purpose, appointment_id = v_appt,
    updated_at = now();
  if p_submit then
    v_req := inspection_make_requests(p_id);
    select * into r from inspections where id = p_id;
    -- The appointment it was for: the one chosen, else the unit's scheduled appointment within a week of the date.
    if v_appt is null then
      select a.id into v_appt from inspection_appointments a where a.property_id = p_property and a.unit = p_unit and a.status = 'scheduled'
        and abs((a.starts_at at time zone 'America/Chicago')::date - r.inspected_on) <= 7
      order by abs((a.starts_at at time zone 'America/Chicago')::date - r.inspected_on) limit 1;
      if v_appt is not null then update inspections set appointment_id = v_appt where id = p_id; end if;
    end if;
    if v_appt is not null then
      update inspection_appointments set status = 'done', inspection_id = p_id where id = v_appt and status = 'scheduled';
    end if;
    -- Routine and annual inspections restart the clock on a unit with its own schedule.
    if r.purpose in ('routine', 'annual') then
      update inspection_schedules set next_due = (r.inspected_on + make_interval(months => frequency_months))::date, updated_at = now(), updated_by = 'inspection ' || to_char(r.inspected_on, 'FMMM/FMDD/YYYY')
       where property_id = p_property and unit = p_unit and (next_due is null or next_due <= (r.inspected_on + make_interval(months => frequency_months))::date);
    end if;
  end if;
  return jsonb_build_object('id', p_id, 'status', case when p_submit then 'submitted' else 'draft' end, 'requests_created', v_req, 'purpose', v_purpose, 'appointment_id', v_appt);
end;
$$;
revoke all on function field_save_inspection(uuid, text, text, date, jsonb, boolean, text, uuid) from public, anon;
grant execute on function field_save_inspection(uuid, text, text, date, jsonb, boolean, text, uuid) to authenticated;

-- Field page reads: add the purpose (and appointment) to the existing outputs.
create or replace function field_list_inspections(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'inspected_on', i.inspected_on, 'status', i.status, 'inspector', i.inspector_email, 'purpose', i.purpose,
      'needs_repair', (select count(*) from jsonb_each(i.data -> 'items') e where e.value ->> 's' = 'Needs repair'))
      order by i.inspected_on desc, i.created_at desc)
    from inspections i where i.property_id = p_property and i.unit = p_unit), '[]'::jsonb);
end;
$$;

create or replace function field_get_inspection(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare r inspections;
begin
  select * into r from inspections where id = p_id;
  if not found or not field_can_access(r.property_id, r.unit) then return null; end if;
  return jsonb_build_object('id', r.id, 'property_id', r.property_id, 'unit', r.unit, 'inspector', r.inspector_email,
    'inspected_on', r.inspected_on, 'status', r.status, 'data', r.data, 'purpose', r.purpose, 'appointment_id', r.appointment_id);
end;
$$;

create or replace function inspections_staff_list(p_limit int default 300)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(q.x order by q.inspected_on desc, q.created_at desc) from (
    select jsonb_build_object('id', i.id, 'property_id', i.property_id, 'unit', i.unit, 'inspector', i.inspector_email, 'inspected_on', i.inspected_on, 'status', i.status,
             'submitted_at', i.submitted_at, 'purpose', i.purpose,
             'needs_repair', (select count(*) from jsonb_each(i.data -> 'items') e where e.value ->> 's' = 'Needs repair'),
             'checked', (select count(*) from jsonb_each(i.data -> 'items') e where coalesce(e.value ->> 's', '') <> ''),
             'requests', (select count(*) from inspection_requests r where r.inspection_id = i.id)) x, i.inspected_on, i.created_at
    from inspections i order by i.inspected_on desc, i.created_at desc limit greatest(least(coalesce(p_limit, 300), 1000), 1)) q), '[]'::jsonb);
end;
$$;

create or replace function inspections_staff_get(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r inspections;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from inspections where id = p_id;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'property_id', r.property_id, 'unit', r.unit, 'inspector', r.inspector_email, 'inspected_on', r.inspected_on,
    'status', r.status, 'submitted_at', r.submitted_at, 'data', r.data, 'purpose', r.purpose, 'purpose_label', inspection_purpose_label(r.purpose),
    'requests', coalesce((select jsonb_object_agg(q.item_key, jsonb_build_object('id', m.id, 'number', m.number, 'status', m.status))
                          from inspection_requests q join maintenance_requests m on m.id = q.request_id where q.inspection_id = r.id), '{}'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff: schedules
create or replace function inspection_schedule_set(p_property text, p_unit text, p_months int, p_next_due date, p_inspector text, p_active boolean, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare s inspection_schedules;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if inspection_rental_unit(p_property, p_unit) is null then raise exception 'Unit % isn''t on file.', p_unit; end if;
  if p_months is null or p_months not between 1 and 60 then raise exception 'Choose how often: 1 to 60 months.'; end if;
  if nullif(trim(coalesce(p_inspector, '')), '') is not null and not exists (
       select 1 from field_staff where active and lower(email) = lower(trim(p_inspector)) union all select 1 from condo_staff where lower(email) = lower(trim(p_inspector))) then
    raise exception 'The inspector must be office or field staff (%).', trim(p_inspector); end if;
  insert into inspection_schedules (property_id, unit, frequency_months, next_due, inspector_email, active, note, updated_by, updated_at)
  values (p_property, p_unit, p_months, p_next_due, lower(nullif(trim(coalesce(p_inspector, '')), '')), coalesce(p_active, true), nullif(trim(coalesce(p_note, '')), ''), lower(auth.email()), now())
  on conflict (property_id, unit) do update set frequency_months = excluded.frequency_months, next_due = excluded.next_due, inspector_email = excluded.inspector_email,
    active = excluded.active, note = excluded.note, updated_by = excluded.updated_by, updated_at = now()
  returning * into s;
  return to_jsonb(s);
end;
$$;
revoke all on function inspection_schedule_set(text, text, int, date, text, boolean, text) from public, anon;
grant execute on function inspection_schedule_set(text, text, int, date, text, boolean, text) to authenticated;

-- Give every unit (or only those without a schedule) the same frequency. Next due = last routine/annual
-- inspection + frequency, or today for a unit never inspected. Returns how many units were set.
create or replace function inspection_schedule_bulk(p_months int, p_overwrite boolean)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_months is null or p_months not between 1 and 60 then raise exception 'Choose how often: 1 to 60 months.'; end if;
  with u as (
    select inspection_pid_for(ru.address) pid, ru.unit_number unit,
      (select max(i.inspected_on) from inspections i where i.property_id = inspection_pid_for(ru.address) and i.unit = ru.unit_number and i.status = 'submitted' and i.purpose in ('routine', 'annual')) last_done
    from rental_units ru where ru.unit_number is not null and inspection_pid_for(ru.address) is not null),
  ins as (
    insert into inspection_schedules (property_id, unit, frequency_months, next_due, updated_by, updated_at)
    select pid, unit, p_months, coalesce((last_done + make_interval(months => p_months))::date, current_date), lower(auth.email()), now() from u
    on conflict (property_id, unit) do update set frequency_months = excluded.frequency_months, next_due = excluded.next_due, updated_by = excluded.updated_by, updated_at = now()
      where p_overwrite
    returning 1)
  select count(*) into n from ins;
  return n;
end;
$$;
revoke all on function inspection_schedule_bulk(int, boolean) from public, anon;
grant execute on function inspection_schedule_bulk(int, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff: appointments
create or replace function inspection_appointments_list(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not ((condo_is_staff() and condo_session_ok()) or field_is_staff()) then raise exception 'Staff sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'inspectors', (select coalesce(jsonb_agg(jsonb_build_object('email', e, 'name', n) order by n), '[]'::jsonb) from (
       select lower(email) e, coalesce(name, email) n from field_staff where active
       union select lower(email), coalesce(name, email) from condo_staff) x),
    'appointments', coalesce((select jsonb_agg(inspection_appt_row(a) order by a.starts_at) from inspection_appointments a
      where (a.starts_at at time zone 'America/Chicago')::date between coalesce(p_from, current_date - 30) and coalesce(p_to, current_date + 120)
        and field_can_access(a.property_id, a.unit)), '[]'::jsonb));
end;
$$;
revoke all on function inspection_appointments_list(date, date) from public, anon;
grant execute on function inspection_appointments_list(date, date) to authenticated;

-- Book an appointment. Occupied unit: p_notice = true makes the 12-hour notice (returned for the notices
-- function to turn into the PDF, file and email; start must be 12+ hours away); otherwise p_consent must say
-- how and when the tenant agreed, and the tenants get a confirmation email. Vacant unit: no notice needed.
create or replace function inspection_appointment_create(p_property text, p_unit text, p_purpose text, p_start timestamptz, p_end timestamptz,
  p_inspector text, p_note text, p_notice boolean, p_consent text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a inspection_appointments; v_lease uuid; v_basis text; v_tpl uuid; v_html text; t record; v_insp text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if inspection_rental_unit(p_property, p_unit) is null then raise exception 'Unit % isn''t on file.', p_unit; end if;
  if coalesce(p_purpose, 'routine') not in ('routine', 'annual', 'pre_move_out', 'follow_up', 'complaint', 'other') then raise exception 'Unknown inspection purpose'; end if;
  if p_start is null or p_end is null or p_end <= p_start then raise exception 'Enter the date and a time window (end after start).'; end if;
  if p_start < now() then raise exception 'The appointment can''t start in the past.'; end if;
  if exists (select 1 from inspection_appointments x where x.property_id = p_property and x.unit = p_unit and x.status = 'scheduled'
             and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_start, p_end)) then raise exception 'This unit already has an inspection booked at that time.'; end if;
  v_insp := lower(nullif(trim(coalesce(p_inspector, '')), ''));
  if v_insp is null then select inspector_email into v_insp from inspection_schedules where property_id = p_property and unit = p_unit; end if;
  v_lease := inspection_active_lease(p_property, p_unit);
  if v_lease is null then v_basis := 'vacant';
  elsif coalesce(p_notice, true) then
    if p_start < now() + interval '12 hours' then raise exception 'With a 12-hour notice the inspection must start at least 12 hours from now (after %).',
      to_char((now() + interval '12 hours') at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM'); end if;
    v_basis := 'notice';
  else
    if length(trim(coalesce(p_consent, ''))) < 5 then raise exception 'Without a notice, say how and when the tenant agreed to this entry (e.g. "Agreed by phone 10/7").'; end if;
    v_basis := 'consent';
  end if;
  insert into inspection_appointments (property_id, unit, lease_id, purpose, starts_at, ends_at, inspector_email, entry_basis, consent_note, note, created_by)
  values (p_property, p_unit, v_lease, coalesce(p_purpose, 'routine'), p_start, p_end, v_insp, v_basis,
          case when v_basis = 'consent' then left(trim(p_consent), 300) end, left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()))
  returning * into a;
  if v_basis = 'notice' then
    select id into v_tpl from letter_templates where legacy_id = '2c-12-hour-inspection';
    v_html := letter_render_ctx('2c-12-hour-inspection', v_lease, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', lower(inspection_purpose_label(a.purpose)) || ' of the unit' || coalesce(' (' || a.note || ')', '')));
  elsif v_basis = 'consent' then
    for t in select y.name, y.email from lease_tenants lt join tenants y on y.id = lt.tenant_id where lt.lease_id = v_lease and y.email is not null loop
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Unit inspection: ' || to_char(p_start at time zone 'America/Chicago', 'FMMM/FMDD'),
        tenant_email_wrap(split_part(t.name, ' ', 1), '<p>As you agreed, we will do a <b>' || lower(inspection_purpose_label(a.purpose)) || '</b> of your unit on <b>'
          || inspection_window_text(p_start, p_end) || '</b>.</p>' || coalesce('<p>' || repair_esc(a.note) || '</p>', '')
          || '<p>Questions or a better time? Call ' || coalesce((select value from portal_settings where key = 'org_phone'), 'the office') || '.</p>'), 'inspection');
    end loop;
    update inspection_appointments set notice_sent_at = now() where id = a.id returning * into a;
  end if;
  if v_insp is not null and v_insp <> lower(auth.email()) then
    insert into email_outbox (to_email, subject, html, kind) values (v_insp, 'Inspection booked — Unit ' || a.unit || ', ' || to_char(p_start at time zone 'America/Chicago', 'FMMM/FMDD'),
      '<p>You are booked for a <b>' || lower(inspection_purpose_label(a.purpose)) || '</b> of <b>Unit ' || repair_esc(a.unit) || '</b> on <b>' || inspection_window_text(p_start, p_end) || '</b>.</p>'
      || case v_basis when 'notice' then '<p>The tenant gets the 12-hour notice to enter.</p>' when 'consent' then '<p>The tenant agreed to the entry: ' || repair_esc(a.consent_note) || '</p>' else '<p>The unit is vacant.</p>' end
      || coalesce('<p>Note: ' || repair_esc(a.note) || '</p>', '')
      || '<p>Start the inspection: https://2ndchinc.org/inspections/unit/?p=' || a.property_id || '&u=' || a.unit || '&purpose=' || a.purpose || '&appt=' || a.id || '</p>', 'inspection');
  end if;
  return inspection_appt_row(a) || jsonb_build_object('notice', v_basis = 'notice', 'template_id', v_tpl, 'html', v_html,
    'notice_subject', 'Notice To Enter — ' || inspection_purpose_label(a.purpose));
end;
$$;
revoke all on function inspection_appointment_create(text, text, text, timestamptz, timestamptz, text, text, boolean, text) from public, anon;
grant execute on function inspection_appointment_create(text, text, text, timestamptz, timestamptz, text, text, boolean, text) to authenticated;

create or replace function inspection_appointment_cancel(p_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a inspection_appointments; t record;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why it''s cancelled.'; end if;
  update inspection_appointments set status = 'cancelled', cancelled_reason = left(trim(p_reason), 300), cancelled_at = now()
   where id = p_id and status = 'scheduled' returning * into a;
  if a.id is null then raise exception 'Only a scheduled appointment can be cancelled.'; end if;
  -- Tenants who were told (notice or confirmation) hear that it's off.
  if a.lease_id is not null and (a.notice_id is not null or a.notice_sent_at is not null) and a.starts_at > now() then
    for t in select y.name, y.email from lease_tenants lt join tenants y on y.id = lt.tenant_id where lt.lease_id = a.lease_id and y.email is not null loop
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Inspection cancelled: ' || to_char(a.starts_at at time zone 'America/Chicago', 'FMMM/FMDD'),
        tenant_email_wrap(split_part(t.name, ' ', 1), '<p>The ' || lower(inspection_purpose_label(a.purpose)) || ' of your unit set for <b>' || inspection_window_text(a.starts_at, a.ends_at)
          || '</b> is <b>cancelled</b>. We won''t enter for it. If we need to reschedule, you''ll get a new notice.</p>'), 'inspection');
    end loop;
  end if;
  if a.inspector_email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (a.inspector_email, 'Inspection cancelled — Unit ' || a.unit,
      '<p>The inspection of Unit ' || repair_esc(a.unit) || ' on ' || inspection_window_text(a.starts_at, a.ends_at) || ' is cancelled: ' || repair_esc(a.cancelled_reason) || '</p>', 'inspection');
  end if;
  return inspection_appt_row(a);
end;
$$;
revoke all on function inspection_appointment_cancel(uuid, text) from public, anon;
grant execute on function inspection_appointment_cancel(uuid, text) to authenticated;

-- The notices function links the filed notice back (kind 'inspection'); same function as 20261025000000 plus that kind.
create or replace function notice_link_back(p_kind text, p_id uuid, p_notice uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_kind = 'renewal' then update lease_renewals set notice_id = p_notice where id = p_id;
  elsif p_kind = 'rent_change' then update lease_rent_changes set notice_id = p_notice where id = p_id;
  elsif p_kind = 'repair' then update maintenance_requests set entry_notice_id = p_notice where id = p_id;
  elsif p_kind = 'move_out' then update move_outs set letter_notice_id = p_notice where id = p_id;
  elsif p_kind = 'inspection' then update inspection_appointments set notice_id = p_notice, notice_sent_at = now() where id = p_id;
  end if;
end;
$$;
revoke all on function notice_link_back(text, uuid, uuid) from public, anon, authenticated;
grant execute on function notice_link_back(text, uuid, uuid) to service_role;

-- Office digest: overdue, due within 30 days, and the next 14 days of appointments. Queued to p_to (default: office email).
create or replace function inspections_digest(p_to text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare d jsonb := inspections_due(); v_to text; v_over text; v_soon text; v_appts text; n_over int; n_soon int; n_appt int;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  v_to := coalesce(nullif(trim(coalesce(p_to, '')), ''), (select value from portal_settings where key = 'office_email'), auth.email());
  select count(*), string_agg('<li>Unit ' || repair_esc(u ->> 'unit') || ' — ' || case when u ->> 'state' = 'never' then 'never inspected' else 'was due ' || to_char((u ->> 'due_on')::date, 'FMMM/FMDD/YYYY') end
           || case when u -> 'next_appt' <> 'null'::jsonb then ' (booked ' || to_char(((u -> 'next_appt' ->> 'starts_at')::timestamptz) at time zone 'America/Chicago', 'FMMM/FMDD') || ')' else '' end || '</li>', '')
    into n_over, v_over from jsonb_array_elements(d -> 'units') u where u ->> 'state' in ('never', 'overdue');
  select count(*), string_agg('<li>Unit ' || repair_esc(u ->> 'unit') || ' — due ' || to_char((u ->> 'due_on')::date, 'FMMM/FMDD/YYYY')
           || case when u -> 'next_appt' <> 'null'::jsonb then ' (booked ' || to_char(((u -> 'next_appt' ->> 'starts_at')::timestamptz) at time zone 'America/Chicago', 'FMMM/FMDD') || ')' else '' end || '</li>', '')
    into n_soon, v_soon from jsonb_array_elements(d -> 'units') u where u ->> 'state' = 'soon';
  select count(*), string_agg('<li>' || inspection_window_text(a.starts_at, a.ends_at) || ' — Unit ' || repair_esc(a.unit) || ', ' || lower(inspection_purpose_label(a.purpose))
           || coalesce(' · ' || repair_esc(a.inspector_email), '') || case a.entry_basis when 'notice' then case when a.notice_id is null then ' · <b>notice NOT sent</b>' else ' · notice sent' end
              when 'consent' then ' · tenant agreed' else ' · vacant' end || '</li>', '' order by a.starts_at)
    into n_appt, v_appts from inspection_appointments a where a.status = 'scheduled' and a.starts_at < now() + interval '14 days';
  insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Inspections: ' || n_over || ' overdue, ' || n_soon || ' due soon, ' || n_appt || ' booked',
    '<h3>Overdue or never inspected (' || n_over || ')</h3>' || coalesce('<ul>' || v_over || '</ul>', '<p>None.</p>')
    || '<h3>Due within 30 days (' || n_soon || ')</h3>' || coalesce('<ul>' || v_soon || '</ul>', '<p>None.</p>')
    || '<h3>Booked in the next 14 days (' || n_appt || ')</h3>' || coalesce('<ul>' || v_appts || '</ul>', '<p>None.</p>')
    || '<p>Schedule: https://2ndchinc.org/inspections/schedule/</p>', 'inspection_digest');
  return jsonb_build_object('to', v_to, 'overdue', n_over, 'soon', n_soon, 'booked', n_appt);
end;
$$;
revoke all on function inspections_digest(text) from public, anon;
grant execute on function inspections_digest(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Residents: upcoming inspections of their unit (and the last 7 days, so a just-finished one still shows).
create or replace function resident_inspection_appointments()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('office_phone', (select value from portal_settings where key = 'org_phone'),
    'appointments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'unit', a.unit, 'purpose', a.purpose, 'purpose_label', inspection_purpose_label(a.purpose),
        'starts_at', a.starts_at, 'ends_at', a.ends_at, 'window', inspection_window_text(a.starts_at, a.ends_at), 'status', a.status, 'note', a.note,
        'entry_basis', a.entry_basis, 'notice_id', a.notice_id, 'notice_sent_at', a.notice_sent_at, 'cancelled_reason', a.cancelled_reason) order by a.starts_at)
      from inspection_appointments a
      where a.lease_id in (select lt.lease_id from lease_tenants lt where lt.tenant_id in (select resident_me()))
        and a.entry_basis in ('notice', 'consent') and (a.notice_sent_at is not null or a.notice_id is not null)
        and a.ends_at > now() - interval '7 days'), '[]'::jsonb));
end;
$$;
revoke all on function resident_inspection_appointments() from public, anon;
grant execute on function resident_inspection_appointments() to authenticated;

-- Re-make the 12-hour notice for a booked appointment whose notice was never filed (e.g. the PDF step failed).
-- The notice time is now, so the appointment must still start 12+ hours from now.
create or replace function inspection_appointment_notice(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a inspection_appointments;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into a from inspection_appointments where id = p_id;
  if a.id is null or a.status <> 'scheduled' or a.entry_basis <> 'notice' then raise exception 'Only a booked appointment that needs a notice can get one.'; end if;
  if a.notice_id is not null then raise exception 'The notice for this appointment was already sent.'; end if;
  if a.starts_at < now() + interval '12 hours' then raise exception 'Too late for a 12-hour notice: cancel this appointment and book a new time (or record the tenant''s agreement).'; end if;
  return jsonb_build_object('id', a.id, 'lease_id', a.lease_id, 'template_id', (select id from letter_templates where legacy_id = '2c-12-hour-inspection'),
    'notice_subject', 'Notice To Enter — ' || inspection_purpose_label(a.purpose),
    'html', letter_render_ctx('2c-12-hour-inspection', a.lease_id, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(a.starts_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(a.starts_at at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(a.ends_at at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', lower(inspection_purpose_label(a.purpose)) || ' of the unit' || coalesce(' (' || a.note || ')', ''))));
end;
$$;
revoke all on function inspection_appointment_notice(uuid) from public, anon;
grant execute on function inspection_appointment_notice(uuid) to authenticated;
