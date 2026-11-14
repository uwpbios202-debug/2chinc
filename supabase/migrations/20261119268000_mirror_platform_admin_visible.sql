-- The Human Mirror, Phase 2 fix 4 of 15 (Stephen, 11/13/2026): 2nd Chance admins could join any organization unseen.
-- Read on live 11/13: mirror.can_manage_members() lets a platform admin (portal admin, or org_admin of 2nd Chance) save members of ANY
-- organization, including their own email as org_admin or coordinator, which then opens that organization's people to them.
-- The only trace was an audit row the organization cannot see. Now, when a platform admin acts in an organization where they are not
-- that organization's own admin ("from outside"):
--  1. they cannot add, reactivate or promote THEMSELVES there, and cannot change a member's email to their own. To join, that
--     organization's admin adds them.
--  2. every member they add or change is marked (platform_changed_at / platform_changed_by) and the organization's member list shows
--     "Added or changed by <name> (2nd Chance)" with the date.
-- Setting up a new organization's members (e.g. a Navigator business's first admin) still works. No table is created (no new grants).

alter table mirror.organization_members
  add column platform_changed_at timestamptz,
  add column platform_changed_by text;

-- A platform admin acting in an organization they are not an admin of.
create or replace function mirror.platform_outside(p_org uuid) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.is_platform_admin(), false) and not coalesce(mirror.my_role(p_org) = 'org_admin', false);
$$;
revoke all on function mirror.platform_outside(uuid) from public;

create or replace function public.mirror_admin_member_save(p jsonb)
returns uuid
language plpgsql security definer set search_path = mirror, public as $$
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
end $$;

create or replace function public.mirror_admin_members(p_org uuid)
returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
begin
  if not mirror.can_manage_members(p_org) then raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'email', m.auth_email, 'name', m.name, 'role', m.role,
      'active', m.active, 'joined_at', m.joined_at, 'is_me', m.auth_email = lower(auth.email()),
      'platform_changed_at', m.platform_changed_at,
      'platform_changed_by', case when m.platform_changed_by is null then null else coalesce(
        (select pm.name from mirror.organization_members pm join mirror.organizations po on po.id = pm.organization_id
          where po.is_platform_owner and pm.auth_email = m.platform_changed_by limit 1), 'a 2nd Chance admin') end)
      order by m.active desc, m.name)
    from mirror.organization_members m where m.organization_id = p_org), '[]'::jsonb);
end $$;
