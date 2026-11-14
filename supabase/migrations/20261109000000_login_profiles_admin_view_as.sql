-- Login profiles (Stephen, 10/10/2026):
--   * Admin: info@2ndchinc.org (Albert Harris). Sees everything and can open any tenant's, owner's or staff
--     member's portal exactly as that person sees it ("View as", see below).
--   * Field staff and their units (units 1-8 are 6626 N Bourbon, 11-18 are 6622 N Bourbon):
--       Paula Grath      secondchancehousingusa@gmail.com   8, 12, 18
--       Earnest Williams ernestwilliamsvet@gmail.com        2, 3, 4, 5, 11, 14, 18
--       Gavin Dotson     12gavindotson@gmail.com            13, 15, 17
--       Milagros Colon   handywomanangel@gmail.com          6, 16
--       Patrick Island   profpaddyisland@gmail.com          1, 7, 13
--   * Units 1, 7 and 13 are owner-occupied (condo_units.occupancy = 'owner'); the staff pages now say so.
--   * 2nd Chance Housing Inc (units 2, 3, 4, 5, 11, 14) signs in as owner with 2ndchinc@gmail.com (Albert Harris).
--     That address used to be a test office-staff login; it is removed from office staff so the owner view works
--     for it. (Office staff outrank owner, so an address that is both only ever sees the staff side.)

-- ---------------------------------------------------------------------------
-- Admin + office staff
-- ---------------------------------------------------------------------------
create table if not exists portal_admins (
  email text primary key,
  name text
);
alter table portal_admins enable row level security;   -- no policies: read only through the functions below
insert into portal_admins (email, name) values ('info@2ndchinc.org', 'Albert Harris') on conflict (email) do nothing;

insert into condo_staff (email, name, phone_mobile)
values ('info@2ndchinc.org', 'Albert Harris', '(262) 236-5443')
on conflict (email) do update set name = excluded.name;

delete from condo_staff where lower(email) = '2ndchinc@gmail.com';

-- 2nd Chance Housing Inc: the owner login for all of its units.
update condo_owners set email = '2ndchinc@gmail.com'
 where buildium_ids && array['2778252', '2780123'];

-- ---------------------------------------------------------------------------
-- Field staff and their units
-- ---------------------------------------------------------------------------
insert into field_staff (email, name, active) values
  ('secondchancehousingusa@gmail.com', 'Paula Grath', true),
  ('ernestwilliamsvet@gmail.com', 'Earnest Williams', true),
  ('12gavindotson@gmail.com', 'Gavin Dotson', true),
  ('handywomanangel@gmail.com', 'Milagros Colon', true),
  ('profpaddyisland@gmail.com', 'Patrick Island', true)
on conflict (email) do update set name = excluded.name, active = true;

delete from staff_units where lower(email) in (
  'secondchancehousingusa@gmail.com', 'ernestwilliamsvet@gmail.com', '12gavindotson@gmail.com',
  'handywomanangel@gmail.com', 'profpaddyisland@gmail.com');

insert into staff_units (email, property_id, unit)
select v.email, case when v.unit::int <= 8 then '6626-n-bourbon' else '6622-n-bourbon' end, v.unit
from (values
  ('secondchancehousingusa@gmail.com', '8'), ('secondchancehousingusa@gmail.com', '12'), ('secondchancehousingusa@gmail.com', '18'),
  ('ernestwilliamsvet@gmail.com', '2'), ('ernestwilliamsvet@gmail.com', '3'), ('ernestwilliamsvet@gmail.com', '4'), ('ernestwilliamsvet@gmail.com', '5'),
  ('ernestwilliamsvet@gmail.com', '11'), ('ernestwilliamsvet@gmail.com', '14'), ('ernestwilliamsvet@gmail.com', '18'),
  ('12gavindotson@gmail.com', '13'), ('12gavindotson@gmail.com', '15'), ('12gavindotson@gmail.com', '17'),
  ('handywomanangel@gmail.com', '6'), ('handywomanangel@gmail.com', '16'),
  ('profpaddyisland@gmail.com', '1'), ('profpaddyisland@gmail.com', '7'), ('profpaddyisland@gmail.com', '13')
) as v(email, unit);

update condo_units set occupancy = 'owner' where unit_number in ('1', '7', '13');

-- Which units are owner-occupied / tenant / vacant (for the staff "My units" page).
create or replace function field_unit_occupancy()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not mfa_aal_ok() or not (condo_is_staff() or field_is_staff()) then
    raise exception 'Staff only' using errcode = '42501';
  end if;
  return coalesce((select jsonb_object_agg(unit_number, occupancy) from condo_units), '{}'::jsonb);
end;
$$;
revoke all on function field_unit_occupancy() from public, anon;
grant execute on function field_unit_occupancy() to authenticated;

-- ---------------------------------------------------------------------------
-- Admin "View as": the admin opens the real portal as another person.
--
-- The admin-view-as edge function (admin only, authenticator code required) mints a one-time sign-in for the
-- chosen person and records a grant here. The admin's own session is never touched: the new tab keeps its
-- session in that tab only. A grant is tied to ONE session id, so it can't be used by anyone else, and it
-- stands in for the authenticator-app step only for that session and only for 60 minutes.
-- ---------------------------------------------------------------------------
create table if not exists view_as_grants (
  id uuid primary key default gen_random_uuid(),
  admin_email text not null,
  target_email text not null,
  target_user_id uuid not null,
  session_id uuid,                        -- filled in when the new session is bound
  created_at timestamptz not null default now(),
  bound_at timestamptz,
  expires_at timestamptz not null default now() + interval '60 minutes'
);
create index if not exists view_as_grants_session_idx on view_as_grants (session_id);
alter table view_as_grants enable row level security;   -- service role only; also our audit log of who looked at whose portal

create or replace function portal_is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
    and exists (select 1 from portal_admins where lower(email) = lower(auth.email()))
    and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2');
$$;
revoke all on function portal_is_admin() from public, anon;
grant execute on function portal_is_admin() to authenticated;

-- A view-as session counts as having passed the authenticator step.
create or replace function mfa_aal_ok()
returns boolean
language sql stable security definer set search_path = public as $$
  select not mfa_required()
      or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      or exists (select 1 from view_as_grants g
                 where g.session_id is not null
                   and g.session_id::text = (auth.jwt() ->> 'session_id')
                   and g.target_user_id = auth.uid()
                   and g.expires_at > now());
$$;
revoke all on function mfa_aal_ok() from public, anon;
grant execute on function mfa_aal_ok() to authenticated;

-- Everyone who can sign in, with the portal each would see. Admin only.
create or replace function admin_login_directory()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not portal_is_admin() then raise exception 'Admin only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'staff', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Office staff (all units)') order by name) from condo_staff), '[]'::jsonb),
    'field', coalesce((select jsonb_agg(jsonb_build_object('name', f.name, 'email', f.email, 'kind', 'Field staff',
        'units', (select string_agg(su.unit, ', ' order by su.unit::int) from staff_units su where lower(su.email) = lower(f.email))) order by f.name)
      from field_staff f where f.active), '[]'::jsonb),
    'agents', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Lease agent') order by name) from lease_agents where active), '[]'::jsonb),
    'owners', coalesce((select jsonb_agg(jsonb_build_object('name', o.name, 'email', o.email, 'kind', 'Owner',
        'units', condo_unit_label(o.id)) order by o.name)
      from condo_owners o where condo_owner_for_email(o.email) is not null), '[]'::jsonb),
    'tenants', coalesce((select jsonb_agg(x order by nullif(regexp_replace(coalesce(x ->> 'unit', ''), '\D', '', 'g'), '')::int nulls last, x ->> 'name') from (
        select jsonb_build_object('name', t.name, 'email', t.email, 'kind', 'Tenant', 'unit', ru.unit_number) x
        from tenants t
        join lease_tenants lt on lt.tenant_id = t.id
        join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
        join rental_units ru on ru.id = l.unit_id
        where exists (select 1 from resident_tenant_ids(t.email))
        union
        select jsonb_build_object('name', t.name, 'email', t.email, 'kind', 'Land-contract buyer', 'unit', null::text)
        from land_contract_buyers b join tenants t on t.id = b.tenant_id join land_contracts c on c.id = b.contract_id and c.status = 'active') s), '[]'::jsonb)
  );
end;
$$;
revoke all on function admin_login_directory() from public, anon;
grant execute on function admin_login_directory() to authenticated;

-- Which portal an email lands in (same precedence as condo_whoami). Called by the admin-view-as function only.
create or replace function admin_role_for_email(p_email text)
returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from condo_staff where lower(email) = lower(p_email)) then 'staff'
    when condo_owner_for_email(p_email) is not null then 'owner'
    when exists (select 1 from lease_agents where active and lower(email) = lower(p_email)) then 'agent'
    when exists (select 1 from resident_tenant_ids(p_email)) then 'resident'
    when exists (select 1 from field_staff where active and lower(email) = lower(p_email)) then 'field'
    else 'none' end;
$$;
revoke all on function admin_role_for_email(text) from public, anon, authenticated;
grant execute on function admin_role_for_email(text) to service_role;
