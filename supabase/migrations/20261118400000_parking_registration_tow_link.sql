-- Parking: registration for everyone who parks here, and Always Towing's private vehicle page (Stephen, 11/8/2026).
--   * Registration deadline 11/18/2026; Always Towing's first patrol 11/20/2026. From then on Always Towing may tow any vehicle in a numbered
--     stall that is not registered to the unit using that stall today (switches and holds count), and residents keep the tow button.
--   * Who registers a stall's vehicles (vehicle_reg_units): tenants on an active lease (as before), owner-occupants (Units 1, 7, 13), owners of a
--     unit with no active lease (vacant, e.g. 15 and 17), and the parking-and-keys person of an owner-managed unit (Unit 6, unit_occupants).
--     An owner whose unit has an active lease does not register: the tenant does.
--   * Always Towing opens https://2ndchinc.org/towing/#k=<key> (no sign-in, Stephen chose a private link). Only the SHA-256 of the key is
--     stored (portal_settings.tow_link_hash); the edge function tow-view checks it and returns tow_lot_view() with signed photo links.
--     The key is never in git. Staff can make a new link (the old one stops working) with tow_link_new() on the staff Parking page.
--   * Unit 6's occupant is never named on staff screens or office emails (CLAUDE.md): their registrations are marked "unit occupant".
-- New table tow_link_views: explicit grants (Supabase change of 10/30/2026).

insert into portal_settings (key, value) values ('vehicle_register_by', '2026-11-18') on conflict (key) do nothing;
insert into portal_settings (key, value) values ('tow_enforce_from', '2026-11-20') on conflict (key) do nothing;
insert into portal_settings (key, value) values ('tow_contact_phone', '414-870-6121') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Who registers which stall
create or replace function vehicle_reg_units()
returns table (unit_number text, role text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u
  union
  select u, 'occupant' from occupant_my_units() u
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and cu.unit_number <> all (owner_direct_unit_list())
     and (cu.occupancy = 'owner' or not exists (select 1 from leases l join rental_units ru on ru.id = l.unit_id
                                                 where l.status = 'active' and ru.unit_number = cu.unit_number));
$$;
revoke all on function vehicle_reg_units() from public, anon;
grant execute on function vehicle_reg_units() to authenticated;

-- Photos: the same people may upload to their unit's folder.
drop policy if exists "vehicles upload own unit" on storage.objects;
create policy "vehicles upload own unit" on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicles' and ((storage.foldername(name))[1] in (select unit_number from vehicle_reg_units()) or condo_is_staff()));
drop policy if exists "vehicles replace own unit" on storage.objects;
create policy "vehicles replace own unit" on storage.objects for update to authenticated
  using (bucket_id = 'vehicles' and ((storage.foldername(name))[1] in (select unit_number from vehicle_reg_units()) or condo_is_staff()));

-- Who did it, as the office sees it (never the Unit 6 occupant's name or email).
create or replace function vehicle_reg_who(p_role text)
returns text
language sql stable security definer set search_path = public as $$
  select case p_role
    when 'occupant' then 'the unit''s occupant (owner-managed unit)'
    when 'owner' then coalesce((select name from condo_owners where id = condo_owner_for_email(auth.email())), auth.email()) || ' (owner)'
    else coalesce((select t.name from tenants t where t.id in (select resident_me()) limit 1), auth.email()) end;
$$;
revoke all on function vehicle_reg_who(text) from public, anon, authenticated;

-- What the portal shows: each unit I register for, its vehicles and answers, and the dates.
create or replace function vehicle_reg_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return jsonb_build_object(
    'register_by', condo_setting('vehicle_register_by', ''), 'enforce_from', condo_setting('tow_enforce_from', ''),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', r.unit_number, 'role', r.role,
        'vehicles', coalesce((select jsonb_agg(to_jsonb(v) - 'lease_id' - 'tenant_id' - 'registered_by' order by v.created_at desc)
                              from vehicles v where v.unit_number = r.unit_number and v.status = 'active'), '[]'::jsonb),
        'declaration', (select to_jsonb(d) - 'lease_id' - 'tenant_id' - 'declared_by' from parking_declarations d where d.unit_number = r.unit_number))
      order by nullif(regexp_replace(r.unit_number, '\D', '', 'g'), '')::int) from vehicle_reg_units() r), '[]'::jsonb));
end;
$$;
revoke all on function vehicle_reg_mine() from public, anon;
grant execute on function vehicle_reg_mine() to authenticated;

create or replace function vehicle_reg_save(
  p_unit text, p_id uuid, p_kind text, p_make text, p_model text, p_color text, p_year int, p_plate text, p_plate_state text,
  p_loaner_reason text, p_loaner_lender text, p_loaner_from date, p_loaner_until date,
  p_visitor_name text, p_visitor_relationship text, p_visitor_frequency text, p_notes text, p_front text, p_back text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_role text; v_lease uuid; v_tenant uuid; v_id uuid := coalesce(p_id, gen_random_uuid()); v_new boolean; v_row vehicles;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select role into v_role from vehicle_reg_units() where unit_number = p_unit limit 1;
  if v_role is null then raise exception 'You can register vehicles only for your own unit''s stall.' using errcode = '42501'; end if;
  if p_kind not in ('own', 'loaner', 'visitor') then raise exception 'Choose the kind of vehicle'; end if;
  if v_role = 'tenant' then
    select l.id, lt.tenant_id into v_lease, v_tenant from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active'
      join rental_units ru on ru.id = l.unit_id where ru.unit_number = p_unit and lt.tenant_id in (select resident_me()) limit 1;
  end if;

  if p_kind in ('own', 'loaner') then
    if coalesce(trim(p_make), '') = '' or coalesce(trim(p_model), '') = '' or coalesce(trim(p_color), '') = '' or coalesce(trim(p_plate), '') = '' then
      raise exception 'Enter the make, model, color and license plate'; end if;
    if p_front is null or p_back is null then raise exception 'Add a photo of the front and a photo of the back'; end if;
  end if;
  if p_kind = 'loaner' and (coalesce(trim(p_loaner_reason), '') = '' or p_loaner_until is null) then
    raise exception 'Tell us why you have a loaner and the day you will return it'; end if;
  if p_kind = 'visitor' and (coalesce(trim(p_visitor_name), '') = '' or coalesce(trim(p_visitor_frequency), '') = '') then
    raise exception 'Enter the visitor''s name and how often they park here'; end if;
  if p_year is not null and (p_year < 1950 or p_year > extract(year from now())::int + 2) then raise exception 'Check the year'; end if;
  if p_front is not null and p_front not like p_unit || '/' || v_id || '/%' then raise exception 'Bad photo'; end if;
  if p_back is not null and p_back not like p_unit || '/' || v_id || '/%' then raise exception 'Bad photo'; end if;

  v_new := not exists (select 1 from vehicles where id = v_id);
  if not v_new and not exists (select 1 from vehicles where id = v_id and unit_number = p_unit) then raise exception 'That is not your vehicle'; end if;
  if v_new then
    if p_kind = 'own' and exists (select 1 from vehicles where unit_number = p_unit and kind = 'own' and status = 'active') then
      raise exception 'Your unit has one parking stall and already has a vehicle registered. Remove it first, or register a loaner.'; end if;
    if p_kind = 'loaner' and exists (select 1 from vehicles where unit_number = p_unit and kind = 'loaner' and status = 'active') then
      raise exception 'You already have a loaner registered. Remove it first.'; end if;
    if p_kind = 'visitor' and (select count(*) from vehicles where unit_number = p_unit and kind = 'visitor' and status = 'active') >= 3 then
      raise exception 'You can register up to three regular visitors. Remove one first.'; end if;
  end if;

  insert into vehicles (id, unit_number, lease_id, tenant_id, kind, make, model, color, year, plate, plate_state, loaner_reason, loaner_lender, loaner_from, loaner_until,
                        visitor_name, visitor_relationship, visitor_frequency, notes, front_path, back_path, registered_by)
  values (v_id, p_unit, v_lease, v_tenant, p_kind, nullif(trim(p_make), ''), nullif(trim(p_model), ''), nullif(trim(p_color), ''), p_year, upper(nullif(trim(p_plate), '')), upper(nullif(trim(p_plate_state), '')),
          nullif(trim(p_loaner_reason), ''), nullif(trim(p_loaner_lender), ''), p_loaner_from, p_loaner_until,
          nullif(trim(p_visitor_name), ''), nullif(trim(p_visitor_relationship), ''), nullif(trim(p_visitor_frequency), ''), nullif(trim(p_notes), ''), p_front, p_back,
          case when v_role = 'occupant' then 'unit occupant' else lower(auth.email()) end)
  on conflict (id) do update set make = excluded.make, model = excluded.model, color = excluded.color, year = excluded.year, plate = excluded.plate, plate_state = excluded.plate_state,
    loaner_reason = excluded.loaner_reason, loaner_lender = excluded.loaner_lender, loaner_from = excluded.loaner_from, loaner_until = excluded.loaner_until,
    visitor_name = excluded.visitor_name, visitor_relationship = excluded.visitor_relationship, visitor_frequency = excluded.visitor_frequency, notes = excluded.notes,
    front_path = coalesce(excluded.front_path, vehicles.front_path), back_path = coalesce(excluded.back_path, vehicles.back_path), updated_at = now();
  select * into v_row from vehicles where id = v_id;
  perform vehicle_alert((case when v_new then 'New vehicle registered' else 'Vehicle updated' end) || ' - Unit ' || p_unit,
    '<p><b>' || case when v_new then 'New vehicle registered' else 'Vehicle updated' end || '</b> for unit ' || p_unit || ' by ' || repair_esc(vehicle_reg_who(v_role)) || '.</p><p>' ||
    repair_esc(vehicle_summary(v_row)) || '</p><p>Photos and details are on the staff Parking page.</p>');
  return v_id;
end;
$$;
revoke all on function vehicle_reg_save(text, uuid, text, text, text, text, int, text, text, text, text, date, date, text, text, text, text, text, text) from public, anon;
grant execute on function vehicle_reg_save(text, uuid, text, text, text, text, int, text, text, text, text, date, date, text, text, text, text, text, text) to authenticated;

create or replace function vehicle_reg_end(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_row vehicles;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  update vehicles set status = 'ended', ended_at = now(), updated_at = now()
   where id = p_id and status = 'active' and unit_number in (select unit_number from vehicle_reg_units()) returning * into v_row;
  if v_row.id is null then raise exception 'Vehicle not found'; end if;
  perform vehicle_alert('Vehicle removed - Unit ' || v_row.unit_number, '<p>Unit ' || v_row.unit_number || ' removed: ' || repair_esc(vehicle_summary(v_row)) || '</p>');
end;
$$;
revoke all on function vehicle_reg_end(uuid) from public, anon;
grant execute on function vehicle_reg_end(uuid) to authenticated;

create or replace function vehicle_reg_declare(p_unit text, p_no_vehicle boolean, p_visitors boolean, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_role text; v_lease uuid; v_tenant uuid;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select role into v_role from vehicle_reg_units() where unit_number = p_unit limit 1;
  if v_role is null then raise exception 'You can answer only for your own unit''s stall.' using errcode = '42501'; end if;
  if v_role = 'tenant' then
    select l.id, lt.tenant_id into v_lease, v_tenant from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active'
      join rental_units ru on ru.id = l.unit_id where ru.unit_number = p_unit and lt.tenant_id in (select resident_me()) limit 1;
  end if;
  insert into parking_declarations (unit_number, lease_id, tenant_id, no_vehicle, has_regular_visitors, visitors_note, declared_by, declared_at)
  values (p_unit, v_lease, v_tenant, coalesce(p_no_vehicle, false), coalesce(p_visitors, false), nullif(trim(p_note), ''),
          case when v_role = 'occupant' then 'unit occupant' else lower(auth.email()) end, now())
  on conflict (unit_number) do update set no_vehicle = excluded.no_vehicle, has_regular_visitors = excluded.has_regular_visitors, visitors_note = excluded.visitors_note,
    declared_by = excluded.declared_by, declared_at = now(), lease_id = excluded.lease_id, tenant_id = excluded.tenant_id;
  perform vehicle_alert('Parking answers - Unit ' || p_unit, '<p>Unit ' || p_unit || ' (' || repair_esc(vehicle_reg_who(v_role)) || ') says: <b>' ||
    case when p_no_vehicle then 'no vehicle' else 'has a vehicle' end || '</b>' || case when p_visitors then ', regular visitors park here' else '' end ||
    coalesce('. Note: ' || repair_esc(nullif(trim(p_note), '')), '') || '.</p>');
end;
$$;
revoke all on function vehicle_reg_declare(text, boolean, boolean, text) from public, anon;
grant execute on function vehicle_reg_declare(text, boolean, boolean, text) to authenticated;

create or replace function vehicle_reg_set_vin(p_id uuid, p_vin text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_vin text := upper(regexp_replace(coalesce(p_vin, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if not exists (select 1 from vehicles v where v.id = p_id and v.status = 'active' and v.kind in ('own', 'loaner')
                   and v.unit_number in (select unit_number from vehicle_reg_units())) then
    raise exception 'Vehicle not found.' using errcode = '42501';
  end if;
  if v_vin <> '' and v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'A VIN has 17 letters and numbers (never I, O or Q).'; end if;
  update vehicles set vin = nullif(v_vin, ''), updated_at = now() where id = p_id;
end;
$$;
revoke all on function vehicle_reg_set_vin(uuid, text) from public, anon;
grant execute on function vehicle_reg_set_vin(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff: every unit stall with nothing registered and no "no vehicle" answer (not only leased units); never show the Unit 6 occupant.
create or replace function vehicles_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) || jsonb_build_object('tenant', (select name from tenants where id = v.tenant_id), 'summary', vehicle_summary(v))
        order by v.status, nullif(regexp_replace(v.unit_number, '\D', '', 'g'), '')::int nulls last, v.created_at desc) from vehicles v), '[]'::jsonb),
    'declarations', coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('tenant', (select name from tenants where id = d.tenant_id)) order by d.unit_number) from parking_declarations d), '[]'::jsonb),
    'units_without', coalesce((select jsonb_agg(s.home_unit order by nullif(regexp_replace(s.home_unit, '\D', '', 'g'), '')::int nulls last) from parking_stalls s
        where s.kind = 'unit' and s.active
          and not exists (select 1 from vehicles v where v.unit_number = s.home_unit and v.status = 'active')
          and not exists (select 1 from parking_declarations d where d.unit_number = s.home_unit and d.no_vehicle)), '[]'::jsonb),
    'register_by', condo_setting('vehicle_register_by', ''), 'enforce_from', condo_setting('tow_enforce_from', ''),
    'tow_link_set', coalesce(condo_setting('tow_link_hash', ''), '') <> '',
    'tow_views', coalesce((select jsonb_agg(jsonb_build_object('at', t.viewed_at) order by t.viewed_at desc) from (select viewed_at from tow_link_views order by viewed_at desc limit 10) t), '[]'::jsonb));
end;
$$;
revoke all on function vehicles_staff_list() from public, anon;
grant execute on function vehicles_staff_list() to authenticated;

-- The staff map listed the people of each unit, including Unit 6's parking-and-keys person: leave them out (CLAUDE.md).
do $$ declare v text := pg_get_functiondef('parking_lot_core(date, boolean)'::regprocedure); n text; begin
  n := replace(v, 'from parking_unit_people(st.used_by) p)', 'from parking_unit_people(st.used_by) p where p.kind <> ''occupant'')');
  if n = v then raise exception 'parking_lot_core changed; update this migration'; end if;
  execute n;
end $$;

-- ---------------------------------------------------------------------------
-- Always Towing's page
create table if not exists tow_link_views (
  id bigint generated always as identity primary key,
  viewed_at timestamptz not null default now(),
  ip text,
  user_agent text
);
alter table tow_link_views enable row level security;
revoke all on tow_link_views from public, anon, authenticated;
grant all on tow_link_views to service_role;

-- The lot today, for the tow company: per stall, the vehicles allowed in it (with plates, VIN and photos), switches, holds, and approved guests.
-- Never names, emails or phones of residents. Called only by the tow-view edge function (service role).
create or replace function tow_lot_view()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'America/Chicago')::date; lot jsonb := parking_lot_core((now() at time zone 'America/Chicago')::date, false);
  v_blocked text[] := coalesce((select array_agg(trim(x)) from unnest(string_to_array(condo_setting('parking_blocked_units', ''), ',')) x where trim(x) <> ''), '{}');
begin
  return jsonb_build_object('date', d, 'generated_at', now(),
    'enforce_from', condo_setting('tow_enforce_from', ''), 'register_by', condo_setting('vehicle_register_by', ''),
    'office_phone', condo_setting('org_phone', ''), 'office_email', 'info@2ndchinc.org',
    'stalls', coalesce((select jsonb_agg(jsonb_build_object(
        'label', s ->> 'label', 'kind', s ->> 'kind', 'home_unit', s ->> 'home_unit', 'used_by', s ->> 'used_by',
        'building', case when s ->> 'kind' = 'unit' then split_part((select address from condo_units where unit_number = s ->> 'home_unit'), ' - ', 1) end,
        'blocked', (s ->> 'used_by') = any (v_blocked),
        'no_vehicle', exists (select 1 from parking_declarations pd where pd.unit_number = s ->> 'used_by' and pd.no_vehicle),
        'swap', s -> 'swap', 'hold', s -> 'hold',
        'hold_plate', (select g.plate || coalesce(' ' || g.plate_state, '') from parking_holds h join guest_requests g on g.id = h.guest_request_id
                        where h.stall_id = (s ->> 'id')::uuid and h.status in ('active', 'ended') and d between h.start_date and h.end_date order by h.created_at desc limit 1),
        'vehicles', case when s ->> 'kind' = 'unit' then coalesce((select jsonb_agg(jsonb_build_object('kind', v.kind, 'make', v.make, 'model', v.model, 'color', v.color,
              'year', v.year, 'plate', v.plate, 'plate_state', v.plate_state, 'vin', v.vin, 'loaner_until', v.loaner_until, 'visitor_frequency', v.visitor_frequency,
              'front_path', v.front_path, 'back_path', v.back_path, 'updated_at', v.updated_at) order by v.kind)
            from vehicles v where v.unit_number = s ->> 'used_by' and v.status = 'active' and (v.kind <> 'loaner' or v.loaner_until is null or v.loaner_until >= d)), '[]'::jsonb)
          else '[]'::jsonb end)
      order by (s ->> 'row')::int, (s ->> 'pos')::int, s ->> 'label') from jsonb_array_elements(lot -> 'stalls') s), '[]'::jsonb),
    'guests', coalesce((select jsonb_agg(jsonb_build_object('unit', g.unit_number, 'vehicle', concat_ws(' ', g.vehicle_color, g.vehicle_make, g.vehicle_model),
        'plate', g.plate, 'plate_state', g.plate_state, 'decal', g.decal_number, 'start_date', g.start_date, 'end_date', g.end_date) order by g.unit_number)
      from guest_requests g where g.status = 'approved' and g.parking and d between g.start_date and g.end_date), '[]'::jsonb));
end;
$$;
revoke all on function tow_lot_view() from public, anon, authenticated;
grant execute on function tow_lot_view() to service_role;

-- Staff: make a new private link for the tow company. Returns the key once; only its hash is kept. The old link stops working.
create or replace function tow_link_new()
returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare k text := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_');
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  insert into portal_settings (key, value) values ('tow_link_hash', encode(extensions.digest(k, 'sha256'), 'hex'))
    on conflict (key) do update set value = excluded.value;
  return k;
end;
$$;
revoke all on function tow_link_new() from public, anon;
grant execute on function tow_link_new() to authenticated;

-- Tenants: the resident Parking tab shows the deadline too.
create or replace function resident_vehicles_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_unit text;
begin
  select u into v_unit from vehicle_my_units() u order by 1 limit 1;
  if v_unit is null then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('unit', v_unit,
    'register_by', condo_setting('vehicle_register_by', ''), 'enforce_from', condo_setting('tow_enforce_from', ''),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) - 'lease_id' - 'tenant_id' - 'registered_by' order by v.status, v.created_at desc) from vehicles v where v.unit_number = v_unit and v.status = 'active'), '[]'::jsonb),
    'declaration', (select to_jsonb(d) - 'lease_id' - 'tenant_id' - 'declared_by' from parking_declarations d where d.unit_number = v_unit));
end;
$$;
revoke all on function resident_vehicles_mine() from public, anon;
grant execute on function resident_vehicles_mine() to authenticated;
