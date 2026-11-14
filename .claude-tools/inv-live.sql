== mirror_admin_member_save
CREATE OR REPLACE FUNCTION public.mirror_admin_member_save(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_email text := lower(trim(coalesce(p ->> 'email', '')));
  v_name text := nullif(trim(p ->> 'name'), '');
  v_role text := coalesce(nullif(p ->> 'role', ''), 'coordinator');
  v_active boolean := coalesce((p ->> 'active')::boolean, true);
  v_old mirror.organization_members;
  v_outside boolean;
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

  v_outside := mirror.platform_outside(v_org);
  if v_outside and v_email = lower(auth.email()) then
    raise exception 'You can''t add or change yourself in another organization with 2nd Chance''s admin powers. Ask that organization''s admin to add you.' using errcode = '42501';
  end if;

  if v_id is null then
    insert into mirror.organization_members (organization_id, auth_email, name, role, active, invited_at, platform_changed_at, platform_changed_by)
    values (v_org, v_email, v_name, v_role, v_active, now(),
            case when v_outside then now() end, case when v_outside then lower(auth.email()) end)
    on conflict (organization_id, auth_email) do update set name = excluded.name, role = excluded.role, active = excluded.active,
      platform_changed_at = coalesce(excluded.platform_changed_at, mirror.organization_members.platform_changed_at),
      platform_changed_by = coalesce(excluded.platform_changed_by, mirror.organization_members.platform_changed_by)
    returning id into v_id;
  else
    update mirror.organization_members set auth_email = v_email, name = v_name, role = v_role, active = v_active,
      platform_changed_at = case when v_outside then now() else platform_changed_at end,
      platform_changed_by = case when v_outside then lower(auth.email()) else platform_changed_by end
     where id = v_id;
  end if;

  -- never leave an organization without an active admin
  if not exists (select 1 from mirror.organization_members where organization_id = v_org and active and role = 'org_admin') then
    raise exception 'An organization needs at least one active admin. Make someone else admin first.' using errcode = '22023';
  end if;
  perform mirror.audit(null, v_org, coalesce(mirror.my_role(v_org), 'platform_admin'), 'member_save', 'organization', 'organization_members', v_id::text);
  return v_id;
exception when unique_violation then
  raise exception 'That email is already a member of this organization.' using errcode = '23505';
end $function$

== mirror_person_add
CREATE OR REPLACE FUNCTION public.mirror_person_add(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
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
  if length(v_name) > 120 then raise exception 'That name is too long.' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, or leave it empty.' using errcode = '22023'; end if;
  if v_year is not null and (v_year < 1900 or v_year > extract(year from now())::int) then raise exception 'Birth year looks wrong.' using errcode = '22023'; end if;
  if v_email is not null and exists (select 1 from mirror.organization_members m where m.auth_email = v_email) then
    raise exception 'That email belongs to a coordinator. Use the person''s own email.' using errcode = '22023';
  end if;
  select id into v_me from mirror.organization_members where organization_id = v_org and auth_email = lower(auth.email());

  -- The same email already has a Mirror (with another organization): link to it as an INVITATION only; never copy or overwrite
  -- their answers or details, and show this organization nothing of theirs until they accept.
  if v_email is not null then select id into v_id from mirror.individuals where auth_email = v_email; end if;
  if v_id is null then
    insert into mirror.individuals (auth_email, preferred_name, legal_name, birth_year, created_by_org)
    values (v_email, v_name, v_legal, v_year, v_org) returning id into v_id;
  end if;
  if exists (select 1 from mirror.organization_individuals where organization_id = v_org and individual_id = v_id) then
    raise exception 'This person is already on your list.' using errcode = '23505';
  end if;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, primary_member_id, invited_name)
  values (v_org, v_id, case when v_email is null then 'active' else 'invited' end, current_date, v_me, v_name);
  perform mirror.audit(v_id, v_org, mirror.my_role(v_org), 'edit', 'general', 'organization_individuals', v_id::text);
  return v_id;
end $function$

