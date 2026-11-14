-- Smoke alarms: the type each alarm is, and an alarm in every unit 2nd Chance Housing owns (Stephen, 11/5/2026).
--   Standard: a combination smoke and carbon monoxide (CO) alarm with a sealed 10-year battery. Anything else shows
--   "Needs upgrade" on https://2ndchinc.org/staff/alarms/ .
--   In each 2nd Chance unit the combo alarm is on the ceiling outside the BR1 door: the two bedroom doors are less than
--   6 feet apart, so one alarm there covers both.
-- The 13 common-area alarms were read from the 11/5 photos: all smoke-only (no CO marking); battery type not legible, so
-- 'unknown' until someone reads the back label (Edit on the staff page).

alter table alarm_points add column if not exists power text not null default 'unknown'
  check (power in ('ten_year', 'battery_9v', 'battery_aa', 'hardwired', 'hardwired_ten_year', 'unknown'));
alter table alarm_points add column if not exists unit_number text;   -- set for an alarm inside a unit; null in common areas

create or replace function alarm_meets_standard(p_kind text, p_power text)
returns boolean
language sql immutable as $$ select p_kind = 'smoke_co' and p_power in ('ten_year', 'hardwired_ten_year'); $$;

-- Staff list: now with power, unit and whether it meets the standard.
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
        'kind', p.kind, 'power', p.power, 'unit', p.unit_number, 'standard', alarm_meets_standard(p.kind, p.power),
        'photo_path', p.photo_path, 'sort', p.sort, 'active', p.active,
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

-- Add or change an alarm, now with its battery / power and (for an in-unit alarm) the unit.
drop function if exists alarm_point_save(uuid, text, text, text, text, boolean, text);
create or replace function alarm_point_save(p_id uuid, p_building text, p_name text, p_location text, p_kind text, p_power text,
                                            p_unit text, p_active boolean, p_photo text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 1 then raise exception 'Give the alarm a name, like "Second floor front".'; end if;
  if p_unit is not null and trim(p_unit) <> '' and not exists (select 1 from condo_units where unit_number = trim(p_unit)) then raise exception 'No such unit.'; end if;
  if p_id is null then
    if p_building not in ('6622', '6626') then raise exception 'Choose the building.'; end if;
    insert into alarm_points (building, name, location, kind, power, unit_number, photo_path, sort)
    values (p_building, trim(p_name), nullif(trim(p_location), ''), coalesce(nullif(p_kind, ''), 'smoke_co'), coalesce(nullif(p_power, ''), 'unknown'),
            nullif(trim(p_unit), ''), nullif(trim(p_photo), ''), coalesce((select max(sort) + 10 from alarm_points where building = p_building), 10))
    returning id into v_id;
  else
    update alarm_points set name = trim(p_name), location = nullif(trim(p_location), ''), kind = coalesce(nullif(p_kind, ''), kind),
           power = coalesce(nullif(p_power, ''), power), unit_number = nullif(trim(p_unit), ''),
           active = coalesce(p_active, active), photo_path = coalesce(nullif(trim(p_photo), ''), photo_path)
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Alarm not found.'; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function alarm_point_save(uuid, text, text, text, text, text, text, boolean, text) from public, anon;
grant execute on function alarm_point_save(uuid, text, text, text, text, text, text, boolean, text) to authenticated;

-- One combo alarm in every unit 2nd Chance Housing owns (portal setting company_owner_id), outside the BR1 door,
-- after that building's common-area alarms in the walking order. Their standard (combo, 10-year) is how 2nd Chance installs them;
-- staff correct it with Edit if one is different.
insert into alarm_points (building, name, location, kind, power, unit_number, sort)
select split_part(cu.address, ' ', 1), 'Unit ' || cu.unit_number || ': outside BR1 door',
       'Ceiling outside the BR1 door (covers both bedrooms; the doors are less than 6 feet apart)', 'smoke_co', 'ten_year', cu.unit_number,
       200 + nullif(regexp_replace(cu.unit_number, '\D', '', 'g'), '')::int
  from condo_units cu
  join condo_ownerships s on s.unit_id = cu.id and s.is_current
 where s.owner_id::text = (select value from portal_settings where key = 'company_owner_id')
   and split_part(cu.address, ' ', 1) in ('6622', '6626')
   and not exists (select 1 from alarm_points a where a.unit_number = cu.unit_number);
