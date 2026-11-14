-- Owners may inspect their own unit(s) (Stephen, 10/31/2026): the pre-move-in inspection (and the other purposes on the same screen)
-- is open to office staff, field staff on their assigned units, and now the CURRENT owner of that unit.
-- field_can_access() is left alone: it also guards keys, unit documents and communications, which owners must not gain.
-- A separate inspection_can_access() = field_can_access() OR "current owner of this unit", used only by the inspection functions
-- and the inspections photo bucket. An owner's submitted inspection is a record for the owner and the office: it does not create
-- repair requests, complete appointments or move the schedule (those stay with staff submissions).

create or replace function inspection_can_access(p_property text, p_unit text) returns boolean
language sql stable security definer set search_path = public as $$
  select field_can_access(p_property, p_unit)
      or (auth.uid() is not null and mfa_aal_ok() and exists (
            select 1 from condo_ownerships s join condo_units u on u.id = s.unit_id
             where s.is_current and s.owner_id = condo_owner_for_email(auth.email())
               and u.unit_number = p_unit and u.address like split_part(p_property, '-', 1) || '%'));
$$;
revoke all on function inspection_can_access(text, text) from public, anon;
grant execute on function inspection_can_access(text, text) to authenticated;

create or replace function field_list_inspections(p_property text, p_unit text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not inspection_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'inspected_on', i.inspected_on, 'status', i.status, 'inspector', i.inspector_email, 'purpose', i.purpose,
      'needs_repair', (select count(*) from jsonb_each(i.data -> 'items') e where e.value ->> 's' = 'Needs repair'))
      order by i.inspected_on desc, i.created_at desc)
    from inspections i where i.property_id = p_property and i.unit = p_unit), '[]'::jsonb);
end;
$$;

create or replace function field_get_inspection(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r inspections;
begin
  select * into r from inspections where id = p_id;
  if not found or not inspection_can_access(r.property_id, r.unit) then return null; end if;
  return jsonb_build_object('id', r.id, 'property_id', r.property_id, 'unit', r.unit, 'inspector', r.inspector_email,
    'inspected_on', r.inspected_on, 'status', r.status, 'data', r.data, 'purpose', r.purpose, 'appointment_id', r.appointment_id);
end;
$$;

create or replace function field_save_inspection(p_id uuid, p_property text, p_unit text, p_date date, p_data jsonb, p_submit boolean default false, p_purpose text default null, p_appointment uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r inspections; v_req int := 0; v_purpose text; v_appt uuid; v_staffside boolean;
begin
  if not inspection_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  v_staffside := field_can_access(p_property, p_unit);
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
  if p_submit and v_staffside then
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

-- The photo bucket: same three rules, owners of the unit included.
drop policy if exists "inspections read own units" on storage.objects;
create policy "inspections read own units" on storage.objects for select to authenticated
  using (bucket_id = 'inspections' and inspection_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]));
drop policy if exists "inspections upload own units" on storage.objects;
create policy "inspections upload own units" on storage.objects for insert to authenticated
  with check (bucket_id = 'inspections' and inspection_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]) and inspection_photo_open(name));
drop policy if exists "inspections delete own units" on storage.objects;
create policy "inspections delete own units" on storage.objects for delete to authenticated
  using (bucket_id = 'inspections' and inspection_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]) and inspection_photo_open(name));
