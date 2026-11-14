-- Staff choose which unit an applicant's lease is for (the unit they asked for is kept as units_requested).
-- The lease builder ("Prepare lease") reads applicant.units, so changing it here changes the unit the tenant is sent to sign.
create or replace function apply_staff_units()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('unit', ru.unit_number,
      'taken', exists (select 1 from leases l where l.unit_id = ru.id and l.status in ('active', 'future'))) order by nullif(regexp_replace(ru.unit_number, '\D', '', 'g'), '')::int)
    from rental_units ru where ru.managed_by <> 'owner'), '[]'::jsonb);
end;
$$;
revoke all on function apply_staff_units() from public, anon;
grant execute on function apply_staff_units() to authenticated;

create or replace function apply_staff_set_unit(p_id uuid, p_unit text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r rental_applications; v_unit rental_units;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from rental_applications where id = p_id for update;
  if r.id is null then raise exception 'Application not found'; end if;
  select * into v_unit from rental_units where unit_number = p_unit and managed_by <> 'owner';
  if v_unit.id is null then raise exception 'Unit % is not a unit we lease.', p_unit; end if;
  if exists (select 1 from leases l where l.unit_id = v_unit.id and l.status in ('active', 'future')) then raise exception 'Unit % already has a lease.', p_unit; end if;
  if exists (select 1 from lease_signing_docs d where d.application_id = p_id and d.status <> 'void') then
    raise exception 'A lease was already sent to sign for this application. Void it first, then change the unit.'; end if;
  update rental_applications
     set applicant = jsonb_set(applicant || case when applicant ? 'units_requested' then '{}'::jsonb else jsonb_build_object('units_requested', coalesce(applicant->'units', '[]'::jsonb)) end,
                               '{units}', jsonb_build_array(p_unit))
   where id = p_id returning * into r;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'unit', p_id, 'lease unit set to ' || p_unit);
  return jsonb_build_object('units', r.applicant->'units');
end;
$$;
revoke all on function apply_staff_set_unit(uuid, text) from public, anon;
grant execute on function apply_staff_set_unit(uuid, text) to authenticated;
