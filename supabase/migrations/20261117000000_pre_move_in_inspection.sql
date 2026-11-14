-- Pre-move-in inspection (Stephen, 10/30/2026): before a new tenant gets the keys, staff records a detailed, dated
-- condition report of the unit (room by room, with photos). It is the staff side of the record that the tenant's own
-- move-in checklist is compared with at move-out. Recommended before keys are handed over, not required.
--   * new inspection purpose 'pre_move_in' (does not restart the periodic clock)
--   * inspection_reopen(): office staff can reopen a submitted inspection as a draft (a mistake, missing photos)
--   * photos can be deleted by staff who may see the unit
--   * move_in_pre_inspections(): the latest pre-move-in report per move-in lease, for the Move-ins page

alter table inspections drop constraint if exists inspections_purpose_chk;
alter table inspections add constraint inspections_purpose_chk
  check (purpose in ('routine', 'annual', 'pre_move_in', 'pre_move_out', 'follow_up', 'complaint', 'other'));

create or replace function inspection_purpose_label(p text)
returns text language sql immutable as $$
  select case p when 'routine' then 'Routine inspection' when 'annual' then 'Annual inspection'
    when 'pre_move_in' then 'Pre-move-in inspection'
    when 'pre_move_out' then 'Pre-move-out inspection' when 'follow_up' then 'Follow-up inspection'
    when 'complaint' then 'Inspection about a complaint' when 'other' then 'Inspection' else coalesce(p, 'Inspection') end;
$$;

-- Same save as 20261106030000, with the new purpose allowed.
create or replace function field_save_inspection(p_id uuid, p_property text, p_unit text, p_date date, p_data jsonb, p_submit boolean default false,
  p_purpose text default null, p_appointment uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r inspections; v_req int := 0; v_purpose text; v_appt uuid; s inspection_schedules;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  if p_purpose is not null and p_purpose not in ('routine', 'annual', 'pre_move_in', 'pre_move_out', 'follow_up', 'complaint', 'other') then raise exception 'Unknown inspection purpose'; end if;
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
    if v_appt is null then
      select a.id into v_appt from inspection_appointments a where a.property_id = p_property and a.unit = p_unit and a.status = 'scheduled'
        and abs((a.starts_at at time zone 'America/Chicago')::date - r.inspected_on) <= 7
      order by abs((a.starts_at at time zone 'America/Chicago')::date - r.inspected_on) limit 1;
      if v_appt is not null then update inspections set appointment_id = v_appt where id = p_id; end if;
    end if;
    if v_appt is not null then
      update inspection_appointments set status = 'done', inspection_id = p_id where id = v_appt and status = 'scheduled';
    end if;
    if r.purpose in ('routine', 'annual') then
      update inspection_schedules set next_due = (r.inspected_on + make_interval(months => frequency_months))::date, updated_at = now(), updated_by = 'inspection ' || to_char(r.inspected_on, 'FMMM/FMDD')
       where property_id = p_property and unit = p_unit and (next_due is null or next_due <= (r.inspected_on + make_interval(months => frequency_months))::date);
    end if;
  end if;
  return jsonb_build_object('id', p_id, 'status', case when p_submit then 'submitted' else 'draft' end, 'requests_created', v_req, 'purpose', v_purpose, 'appointment_id', v_appt);
end;
$$;
revoke all on function field_save_inspection(uuid, text, text, date, jsonb, boolean, text, uuid) from public, anon;
grant execute on function field_save_inspection(uuid, text, text, date, jsonb, boolean, text, uuid) to authenticated;

-- Office staff reopen a submitted inspection (repair requests already made stay, and are not made twice).
create or replace function inspection_reopen(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r inspections;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from inspections where id = p_id;
  if not found then raise exception 'Inspection not found'; end if;
  update inspections set status = 'draft', submitted_at = null, updated_at = now() where id = p_id;
  return jsonb_build_object('id', p_id, 'status', 'draft');
end;
$$;
revoke all on function inspection_reopen(uuid) from public, anon;
grant execute on function inspection_reopen(uuid) to authenticated;

-- Photos: staff who may see the unit can delete a photo they added by mistake.
drop policy if exists "inspections delete own units" on storage.objects;
create policy "inspections delete own units" on storage.objects
  for delete to authenticated
  using (bucket_id = 'inspections' and field_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]));

-- Move-ins page: the latest pre-move-in report for each move-in lease's unit.
create or replace function move_in_pre_inspections()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(q.lease_id, jsonb_build_object('property_id', q.pid, 'unit', q.unit_number,
      'inspection_id', i.id, 'status', i.status, 'inspected_on', i.inspected_on))
    from (select l.id lease_id, u.unit_number,
            case when split_part(coalesce(u.address, ''), ' ', 1) = '6626' then '6626-n-bourbon'
                 when split_part(coalesce(u.address, ''), ' ', 1) = '6622' then '6622-n-bourbon' end pid
          from leases l join rental_units u on u.id = l.unit_id where l.move_in_charges_posted) q
    left join lateral (select x.* from inspections x where x.property_id = q.pid and x.unit = q.unit_number and x.purpose = 'pre_move_in'
                       order by (x.status = 'submitted') desc, x.inspected_on desc, x.created_at desc limit 1) i on true
    where q.pid is not null), '{}'::jsonb);
end;
$$;
revoke all on function move_in_pre_inspections() from public, anon;
grant execute on function move_in_pre_inspections() to authenticated;
