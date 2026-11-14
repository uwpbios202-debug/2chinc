-- Vehicle registration (Stephen, 10/6/2026). Each unit has ONE parking stall.
--   * A tenant registers their own vehicle: make, model, color, year, plate, and a front and a back photo.
--   * If they have a loaner (for example while theirs is in the shop) they say why, who lent it and until when.
--   * If they have no vehicle they say so, and can register a regular visitor who parks in the stall.
--   * Staff get an email each time something is registered or changed.
--   * Every tenant and owner can see the photos and the vehicle (unit, kind, make, model, color) so everyone knows whose
--     car belongs in which stall. The plate NUMBER, the registrant's name and contact details are for staff only
--     (the plate is still readable in the photos).

insert into portal_settings (key, value) values ('vehicle_alert_email', 'info@2ndchinc.org') on conflict (key) do nothing;

create table if not exists vehicles (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  lease_id uuid references leases(id),
  tenant_id uuid references tenants(id),
  kind text not null check (kind in ('own', 'loaner', 'visitor')),
  make text, model text, color text, year int, plate text, plate_state text,
  loaner_reason text, loaner_lender text, loaner_from date, loaner_until date,
  visitor_name text, visitor_relationship text, visitor_frequency text,
  notes text,
  front_path text, back_path text,
  status text not null default 'active' check (status in ('active', 'ended')),
  registered_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ended_at timestamptz
);
create index if not exists vehicles_unit_idx on vehicles (unit_number, status);
alter table vehicles enable row level security;

create table if not exists parking_declarations (
  unit_number text primary key,
  lease_id uuid references leases(id),
  tenant_id uuid references tenants(id),
  no_vehicle boolean not null default false,
  has_regular_visitors boolean not null default false,
  visitors_note text,
  declared_by text,
  declared_at timestamptz not null default now()
);
alter table parking_declarations enable row level security;

-- ---------------------------------------------------------------------------
-- Who is who
create or replace function vehicle_my_units()
returns setof text
language sql stable security definer set search_path = public as $$
  select distinct ru.unit_number from lease_tenants lt
    join leases l on l.id = lt.lease_id and l.status = 'active'
    join rental_units ru on ru.id = l.unit_id
  where lt.tenant_id in (select resident_me()) and ru.unit_number is not null;
$$;
revoke all on function vehicle_my_units() from public, anon;
grant execute on function vehicle_my_units() to authenticated;

create or replace function vehicle_can_view()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from vehicle_my_units())
    or condo_owner_for_email(auth.email()) is not null
    or condo_is_staff());
$$;
revoke all on function vehicle_can_view() from public, anon;
grant execute on function vehicle_can_view() to authenticated;

-- Photos: private bucket, path = <unit number>/<vehicle id>/front.jpg or back.jpg.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vehicles', 'vehicles', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "vehicles read residents owners staff" on storage.objects;
create policy "vehicles read residents owners staff" on storage.objects for select to authenticated
  using (bucket_id = 'vehicles' and vehicle_can_view());
drop policy if exists "vehicles upload own unit" on storage.objects;
create policy "vehicles upload own unit" on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicles' and ((storage.foldername(name))[1] in (select vehicle_my_units()) or condo_is_staff()));
drop policy if exists "vehicles replace own unit" on storage.objects;
create policy "vehicles replace own unit" on storage.objects for update to authenticated
  using (bucket_id = 'vehicles' and ((storage.foldername(name))[1] in (select vehicle_my_units()) or condo_is_staff()));

-- ---------------------------------------------------------------------------
-- Alerts to the office
create or replace function vehicle_alert(p_subject text, p_html text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_to text := coalesce(nullif((select value from portal_settings where key = 'vehicle_alert_email'), ''), 'info@2ndchinc.org');
begin
  insert into email_outbox (to_email, subject, html, kind) values (v_to, p_subject, p_html, 'vehicle');
end;
$$;
revoke all on function vehicle_alert(text, text) from public, anon, authenticated;

create or replace function vehicle_summary(v vehicles)
returns text language sql immutable as $$
  select case v.kind
    when 'visitor' then 'Regular visitor ' || coalesce(v.visitor_name, '') || coalesce(' (' || v.visitor_relationship || ')', '') || ', ' || coalesce(v.visitor_frequency, '') ||
      case when v.plate is not null then ', plate ' || v.plate || coalesce(' ' || v.plate_state, '') else '' end
    else initcap(v.kind) || ': ' || coalesce(v.color, '') || ' ' || coalesce(v.year::text, '') || ' ' || coalesce(v.make, '') || ' ' || coalesce(v.model, '') ||
      ', plate ' || coalesce(v.plate, '?') || coalesce(' ' || v.plate_state, '') ||
      case when v.kind = 'loaner' then ' (loaner' || coalesce(' from ' || v.loaner_lender, '') || coalesce(' until ' || to_char(v.loaner_until, 'FMMM/FMDD/YYYY'), '') || coalesce('; ' || v.loaner_reason, '') || ')' else '' end
  end;
$$;

-- ---------------------------------------------------------------------------
-- Resident: my unit's vehicles and parking answers
create or replace function resident_vehicles_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_unit text;
begin
  select u into v_unit from vehicle_my_units() u order by 1 limit 1;
  if v_unit is null then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('unit', v_unit,
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) - 'lease_id' - 'tenant_id' - 'registered_by' order by v.status, v.created_at desc) from vehicles v where v.unit_number = v_unit and v.status = 'active'), '[]'::jsonb),
    'declaration', (select to_jsonb(d) - 'lease_id' - 'tenant_id' - 'declared_by' from parking_declarations d where d.unit_number = v_unit));
end;
$$;
revoke all on function resident_vehicles_mine() from public, anon;
grant execute on function resident_vehicles_mine() to authenticated;

create or replace function resident_vehicle_save(
  p_id uuid, p_kind text, p_make text, p_model text, p_color text, p_year int, p_plate text, p_plate_state text,
  p_loaner_reason text, p_loaner_lender text, p_loaner_from date, p_loaner_until date,
  p_visitor_name text, p_visitor_relationship text, p_visitor_frequency text, p_notes text, p_front text, p_back text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_unit text; v_lease uuid; v_tenant uuid; v_id uuid := coalesce(p_id, gen_random_uuid()); v_new boolean; v_row vehicles; v_name text;
begin
  select u into v_unit from vehicle_my_units() u order by 1 limit 1;
  if v_unit is null then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if p_kind not in ('own', 'loaner', 'visitor') then raise exception 'Choose the kind of vehicle'; end if;
  select l.id, lt.tenant_id into v_lease, v_tenant from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active'
    join rental_units ru on ru.id = l.unit_id where ru.unit_number = v_unit and lt.tenant_id in (select resident_me()) limit 1;
  select name into v_name from tenants where id = v_tenant;

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
  if p_front is not null and p_front not like v_unit || '/' || v_id || '/%' then raise exception 'Bad photo'; end if;
  if p_back is not null and p_back not like v_unit || '/' || v_id || '/%' then raise exception 'Bad photo'; end if;

  v_new := not exists (select 1 from vehicles where id = v_id);
  if not v_new and not exists (select 1 from vehicles where id = v_id and unit_number = v_unit) then raise exception 'That is not your vehicle'; end if;
  if v_new then
    -- one stall per unit
    if p_kind = 'own' and exists (select 1 from vehicles where unit_number = v_unit and kind = 'own' and status = 'active') then
      raise exception 'Your unit has one parking stall and already has a vehicle registered. Remove it first, or register a loaner.'; end if;
    if p_kind = 'loaner' and exists (select 1 from vehicles where unit_number = v_unit and kind = 'loaner' and status = 'active') then
      raise exception 'You already have a loaner registered. Remove it first.'; end if;
    if p_kind = 'visitor' and (select count(*) from vehicles where unit_number = v_unit and kind = 'visitor' and status = 'active') >= 3 then
      raise exception 'You can register up to three regular visitors. Remove one first.'; end if;
  end if;

  insert into vehicles (id, unit_number, lease_id, tenant_id, kind, make, model, color, year, plate, plate_state, loaner_reason, loaner_lender, loaner_from, loaner_until,
                        visitor_name, visitor_relationship, visitor_frequency, notes, front_path, back_path, registered_by)
  values (v_id, v_unit, v_lease, v_tenant, p_kind, nullif(trim(p_make), ''), nullif(trim(p_model), ''), nullif(trim(p_color), ''), p_year, upper(nullif(trim(p_plate), '')), upper(nullif(trim(p_plate_state), '')),
          nullif(trim(p_loaner_reason), ''), nullif(trim(p_loaner_lender), ''), p_loaner_from, p_loaner_until,
          nullif(trim(p_visitor_name), ''), nullif(trim(p_visitor_relationship), ''), nullif(trim(p_visitor_frequency), ''), nullif(trim(p_notes), ''), p_front, p_back, lower(auth.email()))
  on conflict (id) do update set make = excluded.make, model = excluded.model, color = excluded.color, year = excluded.year, plate = excluded.plate, plate_state = excluded.plate_state,
    loaner_reason = excluded.loaner_reason, loaner_lender = excluded.loaner_lender, loaner_from = excluded.loaner_from, loaner_until = excluded.loaner_until,
    visitor_name = excluded.visitor_name, visitor_relationship = excluded.visitor_relationship, visitor_frequency = excluded.visitor_frequency, notes = excluded.notes,
    front_path = coalesce(excluded.front_path, vehicles.front_path), back_path = coalesce(excluded.back_path, vehicles.back_path), updated_at = now();
  select * into v_row from vehicles where id = v_id;
  perform vehicle_alert((case when v_new then 'New vehicle registered' else 'Vehicle updated' end) || ' - Unit ' || v_unit,
    '<p><b>' || case when v_new then 'New vehicle registered' else 'Vehicle updated' end || '</b> for unit ' || v_unit || ' by ' || coalesce(v_name, auth.email()) || '.</p><p>' ||
    replace(replace(vehicle_summary(v_row), '<', '&lt;'), '>', '&gt;') || '</p><p>Photos and details are on the staff Parking page.</p>');
  return v_id;
end;
$$;
revoke all on function resident_vehicle_save(uuid, text, text, text, text, int, text, text, text, text, date, date, text, text, text, text, text, text) from public, anon;
grant execute on function resident_vehicle_save(uuid, text, text, text, text, int, text, text, text, text, date, date, text, text, text, text, text, text) to authenticated;

create or replace function resident_vehicle_end(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_unit text; v_row vehicles;
begin
  select u into v_unit from vehicle_my_units() u order by 1 limit 1;
  if v_unit is null then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  update vehicles set status = 'ended', ended_at = now(), updated_at = now() where id = p_id and unit_number = v_unit and status = 'active' returning * into v_row;
  if v_row.id is null then raise exception 'Vehicle not found'; end if;
  perform vehicle_alert('Vehicle removed - Unit ' || v_unit, '<p>Unit ' || v_unit || ' removed: ' || replace(replace(vehicle_summary(v_row), '<', '&lt;'), '>', '&gt;') || '</p>');
end;
$$;
revoke all on function resident_vehicle_end(uuid) from public, anon;
grant execute on function resident_vehicle_end(uuid) to authenticated;

create or replace function resident_parking_declare(p_no_vehicle boolean, p_visitors boolean, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_unit text; v_lease uuid; v_tenant uuid; v_name text;
begin
  select u into v_unit from vehicle_my_units() u order by 1 limit 1;
  if v_unit is null then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  select l.id, lt.tenant_id into v_lease, v_tenant from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active'
    join rental_units ru on ru.id = l.unit_id where ru.unit_number = v_unit and lt.tenant_id in (select resident_me()) limit 1;
  select name into v_name from tenants where id = v_tenant;
  insert into parking_declarations (unit_number, lease_id, tenant_id, no_vehicle, has_regular_visitors, visitors_note, declared_by, declared_at)
  values (v_unit, v_lease, v_tenant, coalesce(p_no_vehicle, false), coalesce(p_visitors, false), nullif(trim(p_note), ''), lower(auth.email()), now())
  on conflict (unit_number) do update set no_vehicle = excluded.no_vehicle, has_regular_visitors = excluded.has_regular_visitors, visitors_note = excluded.visitors_note,
    declared_by = excluded.declared_by, declared_at = now(), lease_id = excluded.lease_id, tenant_id = excluded.tenant_id;
  perform vehicle_alert('Parking answers - Unit ' || v_unit, '<p>Unit ' || v_unit || ' (' || coalesce(v_name, '') || ') says: <b>' ||
    case when p_no_vehicle then 'no vehicle' else 'has a vehicle' end || '</b>' || case when p_visitors then ', regular visitors park here' else '' end ||
    coalesce('. Note: ' || replace(replace(nullif(trim(p_note), ''), '<', '&lt;'), '>', '&gt;'), '') || '.</p>');
end;
$$;
revoke all on function resident_parking_declare(boolean, boolean, text) from public, anon;
grant execute on function resident_parking_declare(boolean, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Everyone who lives or owns here: the vehicles and their photos (no plate number, no names)
create or replace function vehicles_directory()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not vehicle_can_view() then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'unit', v.unit_number, 'kind', v.kind, 'make', v.make, 'model', v.model, 'color', v.color, 'year', v.year,
      'loaner_until', v.loaner_until, 'visitor_frequency', v.visitor_frequency, 'front_path', v.front_path, 'back_path', v.back_path)
      order by nullif(regexp_replace(v.unit_number, '\D', '', 'g'), '')::int nulls last, v.kind) from vehicles v where v.status = 'active'), '[]'::jsonb);
end;
$$;
revoke all on function vehicles_directory() from public, anon;
grant execute on function vehicles_directory() to authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function vehicles_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) || jsonb_build_object('tenant', (select name from tenants where id = v.tenant_id), 'summary', vehicle_summary(v))
        order by v.status, nullif(regexp_replace(v.unit_number, '\D', '', 'g'), '')::int nulls last, v.created_at desc) from vehicles v), '[]'::jsonb),
    'declarations', coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('tenant', (select name from tenants where id = d.tenant_id)) order by d.unit_number) from parking_declarations d), '[]'::jsonb),
    'units_without', coalesce((select jsonb_agg(x.unit_number order by nullif(regexp_replace(x.unit_number, '\D', '', 'g'), '')::int nulls last) from (
        select distinct ru.unit_number from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number is not null
        and not exists (select 1 from vehicles v where v.unit_number = ru.unit_number and v.status = 'active')
        and not exists (select 1 from parking_declarations d where d.unit_number = ru.unit_number and d.no_vehicle)) x), '[]'::jsonb));
end;
$$;
revoke all on function vehicles_staff_list() from public, anon;
grant execute on function vehicles_staff_list() to authenticated;

create or replace function vehicles_staff_end(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update vehicles set status = 'ended', ended_at = now(), updated_at = now() where id = p_id and status = 'active';
end;
$$;
revoke all on function vehicles_staff_end(uuid) from public, anon;
grant execute on function vehicles_staff_end(uuid) to authenticated;
