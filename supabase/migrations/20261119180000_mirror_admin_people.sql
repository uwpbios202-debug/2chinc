-- The Human Mirror T2.5 (organizations and members) + T2.6 first half (people: add, list, end/restart). No email is sent here:
-- the invitation email waits for Stephen's OK on its wording (D-17), and mirror_signin_enabled stays off.
--
-- Who may do what (all need the authenticator code, aal2, and never in View as):
--   Mirror platform admin = a portal admin (portal_admins) or an active org_admin of the platform owner organization
--                           (2nd Chance Housing Inc): creates and edits organizations, manages every organization's members.
--   org_admin of an organization: manages that organization's members.
--   coordinator or org_admin: adds people to their organization, lists them, ends or restarts the work with them.
-- Every change writes mirror.audit_logs (ids only).

create or replace function mirror.signed_in_member_ok() returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select auth.email() is not null and coalesce(auth.jwt() ->> 'aal', '') = 'aal2' and not coalesce(public.autopay_view_as_session(), true);
$$;

create or replace function mirror.is_platform_admin() returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.signed_in_member_ok(), false) and (
    exists (select 1 from public.portal_admins where lower(email) = lower(auth.email()))
    or exists (select 1 from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id
               where o.is_platform_owner and o.active and m.active and m.role = 'org_admin' and m.auth_email = lower(auth.email())));
$$;

-- The caller's active role in one organization (null when none, or without the authenticator code).
create or replace function mirror.my_role(p_org uuid) returns text
language sql stable security definer set search_path = mirror, public as $$
  select m.role from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active
  where mirror.signed_in_member_ok() and m.organization_id = p_org and m.active and m.auth_email = lower(auth.email());
$$;

create or replace function mirror.can_manage_members(p_org uuid) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.is_platform_admin(), false) or coalesce(mirror.my_role(p_org) = 'org_admin', false);   -- no role = no (never null)
$$;

-- ---------------------------------------------------------------- organizations

create or replace function public.mirror_admin_orgs() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v_admin boolean := mirror.is_platform_admin();
begin
  if not v_admin and not exists (select 1 from mirror.organization_members m where m.auth_email = lower(auth.email()) and m.active and m.role = 'org_admin')
     or not mirror.signed_in_member_ok() then
    raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'platform_admin', v_admin,
    'orgs', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'kind', o.kind, 'active', o.active, 'is_platform_owner', o.is_platform_owner,
        'navigator_id', o.navigator_id,
        'navigator', (select n.name from public.navigators n where n.id = o.navigator_id),
        'members', (select count(*) from mirror.organization_members m where m.organization_id = o.id and m.active),
        'people', (select count(*) from mirror.organization_individuals oi where oi.organization_id = o.id and oi.status <> 'ended'),
        'can_manage', mirror.can_manage_members(o.id)) order by o.is_platform_owner desc, o.name)
      from mirror.organizations o where v_admin or mirror.my_role(o.id) = 'org_admin'), '[]'::jsonb),
    'navigators', case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'name', n.name, 'status', n.status) order by n.name)
      from public.navigators n where n.status in ('preview', 'pilot', 'active')), '[]'::jsonb) else '[]'::jsonb end);
end $$;

create or replace function public.mirror_admin_org_save(p jsonb) returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_name text := nullif(trim(p ->> 'name'), '');
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'nonprofit');
  v_nav uuid := nullif(p ->> 'navigator_id', '')::uuid;
  v_active boolean := coalesce((p ->> 'active')::boolean, true);
begin
  if not mirror.is_platform_admin() then raise exception 'Only 2nd Chance admins can create or change organizations.' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Give the organization a name.' using errcode = '22023'; end if;
  if v_kind not in ('nonprofit', 'agency', 'navigator', 'other') then raise exception 'Unknown kind of organization.' using errcode = '22023'; end if;
  if v_id is null then
    insert into mirror.organizations (name, kind, navigator_id, active) values (v_name, v_kind, v_nav, v_active) returning id into v_id;
  else
    if exists (select 1 from mirror.organizations where id = v_id and is_platform_owner) and not v_active then
      raise exception '2nd Chance Housing Inc cannot be closed.' using errcode = '22023';
    end if;
    update mirror.organizations set name = v_name, kind = v_kind, navigator_id = v_nav, active = v_active where id = v_id;
    if not found then raise exception 'Organization not found.' using errcode = 'P0002'; end if;
  end if;
  perform mirror.audit(null, v_id, 'platform_admin', 'org_save', 'organization', 'organizations', v_id::text);
  return v_id;
exception when unique_violation then
  raise exception 'That Navigator already has an organization.' using errcode = '23505';
end $$;

-- ---------------------------------------------------------------- members

create or replace function public.mirror_admin_members(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
begin
  if not mirror.can_manage_members(p_org) then raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'email', m.auth_email, 'name', m.name, 'role', m.role,
      'active', m.active, 'joined_at', m.joined_at, 'is_me', m.auth_email = lower(auth.email())) order by m.active desc, m.name)
    from mirror.organization_members m where m.organization_id = p_org), '[]'::jsonb);
end $$;

create or replace function public.mirror_admin_member_save(p jsonb) returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_email text := lower(trim(coalesce(p ->> 'email', '')));
  v_name text := nullif(trim(p ->> 'name'), '');
  v_role text := coalesce(nullif(p ->> 'role', ''), 'coordinator');
  v_active boolean := coalesce((p ->> 'active')::boolean, true);
  v_old mirror.organization_members;
begin
  if v_id is not null then
    select * into v_old from mirror.organization_members where id = v_id;
    if not found then raise exception 'Member not found.' using errcode = 'P0002'; end if;
    v_org := v_old.organization_id;
    if v_email = '' then v_email := v_old.auth_email; end if;
  end if;
  if v_org is null or not mirror.can_manage_members(v_org) then raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address.' using errcode = '22023'; end if;
  if v_name is null then raise exception 'Enter the person''s name.' using errcode = '22023'; end if;
  if v_role not in ('org_admin', 'coordinator', 'volunteer') then raise exception 'Unknown role.' using errcode = '22023'; end if;

  if v_id is null then
    insert into mirror.organization_members (organization_id, auth_email, name, role, active, invited_at)
    values (v_org, v_email, v_name, v_role, v_active, now())
    on conflict (organization_id, auth_email) do update set name = excluded.name, role = excluded.role, active = excluded.active
    returning id into v_id;
  else
    update mirror.organization_members set auth_email = v_email, name = v_name, role = v_role, active = v_active where id = v_id;
  end if;

  -- never leave an organization without an active admin
  if not exists (select 1 from mirror.organization_members where organization_id = v_org and active and role = 'org_admin') then
    raise exception 'An organization needs at least one active admin. Make someone else admin first.' using errcode = '22023';
  end if;
  perform mirror.audit(null, v_org, coalesce(mirror.my_role(v_org), 'platform_admin'), 'member_save', 'organization', 'organization_members', v_id::text);
  return v_id;
exception when unique_violation then
  raise exception 'That email is already a member of this organization.' using errcode = '23505';
end $$;

-- ---------------------------------------------------------------- people (coordinators and org admins of the organization)

create or replace function mirror.coordinates(p_org uuid) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.my_role(p_org) in ('org_admin', 'coordinator'), false);   -- no role = no (never null)
$$;

create or replace function public.mirror_people(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', i.id, 'preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'email', i.auth_email, 'birth_year', i.birth_year,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', i.safety_sensitive)
    order by (oi.status = 'ended'), lower(i.preferred_name))
    from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
    where oi.organization_id = p_org), '[]'::jsonb);
end $$;

create or replace function public.mirror_person_add(p jsonb) returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_name text := nullif(trim(p ->> 'preferred_name'), '');
  v_legal text := nullif(trim(p ->> 'legal_name'), '');
  v_email text := nullif(lower(trim(coalesce(p ->> 'email', ''))), '');
  v_year int := nullif(p ->> 'birth_year', '')::int;
  v_me uuid;
  v_id uuid;
begin
  if v_org is null or not mirror.coordinates(v_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Enter the name the person goes by.' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, or leave it empty.' using errcode = '22023'; end if;
  if v_year is not null and (v_year < 1900 or v_year > extract(year from now())::int) then raise exception 'Birth year looks wrong.' using errcode = '22023'; end if;
  if v_email is not null and exists (select 1 from mirror.organization_members m where m.auth_email = v_email) then
    raise exception 'That email belongs to a coordinator. Use the person''s own email.' using errcode = '22023';
  end if;
  select id into v_me from mirror.organization_members where organization_id = v_org and auth_email = lower(auth.email());

  -- The same email already has a Mirror (with another organization): link to it; never copy or overwrite their answers.
  if v_email is not null then select id into v_id from mirror.individuals where auth_email = v_email; end if;
  if v_id is null then
    insert into mirror.individuals (auth_email, preferred_name, legal_name, birth_year, created_by_org)
    values (v_email, v_name, v_legal, v_year, v_org) returning id into v_id;
  end if;
  if exists (select 1 from mirror.organization_individuals where organization_id = v_org and individual_id = v_id) then
    raise exception 'This person is already on your list.' using errcode = '23505';
  end if;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, primary_member_id)
  values (v_org, v_id, case when v_email is null then 'active' else 'invited' end, current_date, v_me);
  perform mirror.audit(v_id, v_org, mirror.my_role(v_org), 'edit', 'general', 'organization_individuals', v_id::text);
  return v_id;
end $$;

-- End the work with a person (they keep their Mirror) or restart it. p_status: 'ended' | 'active' | 'invited'
create or replace function public.mirror_person_status(p_org uuid, p_individual uuid, p_status text) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if p_status not in ('ended', 'active', 'invited') then raise exception 'Unknown status.' using errcode = '22023'; end if;
  update mirror.organization_individuals
     set status = p_status, ended_on = case when p_status = 'ended' then current_date else null end
   where organization_id = p_org and individual_id = p_individual;
  if not found then raise exception 'This person is not on your list.' using errcode = 'P0002'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'edit', 'general', 'organization_individuals', p_status);
end $$;

-- ---------------------------------------------------------------- grants

revoke all on function mirror.signed_in_member_ok(), mirror.is_platform_admin(), mirror.my_role(uuid), mirror.can_manage_members(uuid),
  mirror.coordinates(uuid) from public, anon, authenticated;
grant execute on function mirror.signed_in_member_ok(), mirror.is_platform_admin(), mirror.my_role(uuid), mirror.can_manage_members(uuid),
  mirror.coordinates(uuid) to service_role;

revoke all on function public.mirror_admin_orgs(), public.mirror_admin_org_save(jsonb), public.mirror_admin_members(uuid),
  public.mirror_admin_member_save(jsonb), public.mirror_people(uuid), public.mirror_person_add(jsonb),
  public.mirror_person_status(uuid, uuid, text) from public, anon;
grant execute on function public.mirror_admin_orgs(), public.mirror_admin_org_save(jsonb), public.mirror_admin_members(uuid),
  public.mirror_admin_member_save(jsonb), public.mirror_people(uuid), public.mirror_person_add(jsonb),
  public.mirror_person_status(uuid, uuid, text) to authenticated, service_role;
