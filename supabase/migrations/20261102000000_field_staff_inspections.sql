-- Field staff: people who sign in (emailed code, like everyone else) and may see
-- ONLY the units assigned to them. First use: unit inspections with typed or
-- dictated notes and photos per checklist item.
--
-- Office staff (condo_staff) keep seeing every unit. A field staff member sees
-- the units listed for their email in staff_units, and nothing else.
--
-- Property ids and unit numbers are the ones in site/data/properties.json
-- (e.g. '6626-n-bourbon' / '3'). A property with no units uses unit '_'.
--
-- To add a field staff member and give them units (run in the SQL editor):
--   insert into field_staff (email, name) values ('inspector@example.com', 'Name');
--   insert into staff_units (email, property_id, unit) values
--     ('inspector@example.com', '6626-n-bourbon', '1'),
--     ('inspector@example.com', '6626-n-bourbon', '2');

create table if not exists field_staff (
  email text primary key,
  name text,
  active boolean not null default true
);

create table if not exists staff_units (
  email text not null,
  property_id text not null,
  unit text not null default '_',
  created_at timestamptz not null default now(),
  primary key (email, property_id, unit)
);

create table if not exists inspections (
  id uuid primary key,
  property_id text not null,
  unit text not null default '_',
  inspector_email text not null,
  inspected_on date not null default current_date,
  status text not null default 'draft' check (status in ('draft', 'submitted')),
  data jsonb not null default '{}'::jsonb,   -- { meta:{inspector}, items:{"kitchen|Walls":{s,n,photos:[path]}} }
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists inspections_unit_idx on inspections (property_id, unit, inspected_on desc);

alter table field_staff enable row level security;
alter table staff_units enable row level security;
alter table inspections enable row level security;   -- no policies: reached only through the functions below

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------
create or replace function field_is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from field_staff where lower(email) = lower(auth.email()) and active);
$$;

-- Office staff: every unit. Field staff: assigned units only.
create or replace function field_can_access(p_property text, p_unit text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null and (
    condo_is_staff()
    or (field_is_staff() and exists (
      select 1 from staff_units
      where lower(email) = lower(auth.email()) and property_id = p_property and unit = p_unit))
  );
$$;

-- ---------------------------------------------------------------------------
-- Sign-in plumbing. Based on the LATEST definitions (20261011 resident portal);
-- the only change is that a field staff email now counts as "on file" and gets
-- the 'field' role (lowest precedence: staff, owner, agent, resident, field).
-- ---------------------------------------------------------------------------
create or replace function condo_email_on_file(p_email text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email));
$$;

create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field) then
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident' else 'field' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;
revoke all on function condo_email_on_file(text) from public, anon, authenticated;
grant execute on function condo_email_on_file(text) to service_role;

-- ---------------------------------------------------------------------------
-- Staff-facing functions
-- ---------------------------------------------------------------------------

-- Which units may I see? { all: true } for office staff.
create or replace function field_my_units()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if condo_is_staff() then return jsonb_build_object('all', true, 'units', '[]'::jsonb); end if;
  if not field_is_staff() then raise exception 'Not field staff' using errcode = '42501'; end if;
  return jsonb_build_object('all', false, 'units', coalesce((
    select jsonb_agg(jsonb_build_object('property_id', property_id, 'unit', unit) order by property_id, unit)
    from staff_units where lower(email) = lower(auth.email())), '[]'::jsonb));
end;
$$;

-- Inspections for one unit, newest first (no item data; counts only).
create or replace function field_list_inspections(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'inspected_on', i.inspected_on, 'status', i.status, 'inspector', i.inspector_email,
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
    'inspected_on', r.inspected_on, 'status', r.status, 'data', r.data);
end;
$$;

-- Create or update a draft. The page makes the id so photos can upload before the first save.
create or replace function field_save_inspection(p_id uuid, p_property text, p_unit text, p_date date, p_data jsonb, p_submit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r inspections;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select * into r from inspections where id = p_id;
  if found and (r.property_id <> p_property or r.unit <> p_unit) then raise exception 'Wrong unit' using errcode = '42501'; end if;
  if found and r.status = 'submitted' then raise exception 'This inspection was already submitted' using errcode = '42501'; end if;
  insert into inspections (id, property_id, unit, inspector_email, inspected_on, data, status, submitted_at)
  values (p_id, p_property, p_unit, lower(auth.email()), coalesce(p_date, current_date), coalesce(p_data, '{}'::jsonb),
          case when p_submit then 'submitted' else 'draft' end, case when p_submit then now() end)
  on conflict (id) do update set
    inspected_on = coalesce(p_date, inspections.inspected_on),
    data = coalesce(p_data, inspections.data),
    status = case when p_submit then 'submitted' else 'draft' end,
    submitted_at = case when p_submit then now() else null end,
    updated_at = now();
  return jsonb_build_object('id', p_id, 'status', case when p_submit then 'submitted' else 'draft' end);
end;
$$;

revoke all on function field_is_staff() from public, anon;
revoke all on function field_can_access(text, text) from public, anon;
revoke all on function field_my_units() from public, anon;
revoke all on function field_list_inspections(text, text) from public, anon;
revoke all on function field_get_inspection(uuid) from public, anon;
revoke all on function field_save_inspection(uuid, text, text, date, jsonb, boolean) from public, anon;
revoke all on function condo_whoami() from public, anon;
grant execute on function field_is_staff() to authenticated;
grant execute on function field_can_access(text, text) to authenticated;
grant execute on function field_my_units() to authenticated;
grant execute on function field_list_inspections(text, text) to authenticated;
grant execute on function field_get_inspection(uuid) to authenticated;
grant execute on function field_save_inspection(uuid, text, text, date, jsonb, boolean) to authenticated;
grant execute on function condo_whoami() to authenticated;

-- ---------------------------------------------------------------------------
-- Photos: private bucket, path = <property>/<unit>/<inspection id>/<file>.jpg.
-- Browsers upload directly; the policy checks the unit in the path.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('inspections', 'inspections', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "inspections read own units" on storage.objects;
create policy "inspections read own units" on storage.objects
  for select to authenticated
  using (bucket_id = 'inspections' and field_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]));

drop policy if exists "inspections upload own units" on storage.objects;
create policy "inspections upload own units" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'inspections' and field_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]));
