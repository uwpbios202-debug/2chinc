-- The Human Mirror, Phase 2 finding E (Stephen, 11/13/2026): who is a 2nd Chance PLATFORM admin is an explicit list.
--
-- Until now mirror.is_platform_admin() was true for anyone in public.portal_admins OR anyone who is an active org admin of 2nd Chance
-- Housing (the platform owner organization). So making someone an admin of 2nd Chance's own team silently gave them power over every
-- organization: seeing and changing all organizations' members, adding organizations and their first admins (fix 4 marks those changes).
--
-- From now on a platform admin is someone on mirror.platform_admins (active) who is also an active member of 2nd Chance Housing and signed
-- in with the authenticator code. Being 2nd Chance's org admin manages 2nd Chance's own members only. Leaving 2nd Chance (member made
-- inactive) ends platform power at once, even if the list row is still there.
-- The list starts with exactly who had the power on 11/13/2026 (copied in SQL below; no email is written in this file).
-- Only the 2nd Chance main admin (public.portal_admins) can add or remove platform admins, on https://2ndchinc.org/mirror/admin/ ;
-- every change is in the audit log (platform_admin_add / platform_admin_remove) and on the page; the list can never become empty.
-- New table: row security on, no grants to anon or authenticated (the Mirror's rule), service_role all.

create table mirror.platform_admins (
  auth_email text primary key check (auth_email = lower(auth_email) and auth_email like '%_@_%'),
  name       text not null,
  active     boolean not null default true,
  added_at   timestamptz not null default now(),
  added_by   text not null,        -- the email of who added them, or the migration for the first list
  removed_at timestamptz,
  removed_by text
);
alter table mirror.platform_admins enable row level security;
revoke all on mirror.platform_admins from public, anon, authenticated;
grant all on mirror.platform_admins to service_role;

-- the first list: everyone who was a platform admin under the old rule
insert into mirror.platform_admins (auth_email, name, added_by)
select distinct on (x.email) x.email, x.name, 'migration 20261119269700 (platform admin under the old rule on 11/13/2026)'
from (
  select lower(pa.email) as email,
         coalesce((select m.name from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.is_platform_owner
                   where m.auth_email = lower(pa.email) order by m.active desc limit 1), nullif(pa.name, ''), 'Main admin') as name, 1 as pref
    from public.portal_admins pa where pa.email like '%_@_%'
  union all
  select m.auth_email, m.name, 2
    from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id
   where o.is_platform_owner and o.active and m.active and m.role = 'org_admin'
) x
order by x.email, x.pref;

-- the rule
create or replace function mirror.is_platform_admin()
returns boolean language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.signed_in_member_ok(), false)
    and exists (select 1 from mirror.platform_admins p where p.active and p.auth_email = lower(auth.email()))
    and exists (select 1 from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id
                where o.is_platform_owner and o.active and m.active and m.auth_email = lower(auth.email()));
$$;

-- who may change the list: the 2nd Chance main admin only
create or replace function mirror.can_edit_platform_admins()
returns boolean language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.is_platform_admin(), false)
    and exists (select 1 from public.portal_admins pa where lower(pa.email) = lower(auth.email()));
$$;

revoke all on function mirror.can_edit_platform_admins() from public, anon, authenticated;
grant execute on function mirror.can_edit_platform_admins() to service_role;

-- the list, for platform admins
create or replace function public.mirror_platform_admins()
returns jsonb language plpgsql stable security definer set search_path = mirror, public as $$
declare v_owner uuid;
begin
  if not coalesce(mirror.is_platform_admin(), false) then
    raise exception '2nd Chance platform admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select id into v_owner from mirror.organizations where is_platform_owner;
  return jsonb_build_object(
    'can_edit', mirror.can_edit_platform_admins(),
    'admins', coalesce((select jsonb_agg(jsonb_build_object(
        'email', p.auth_email, 'name', p.name, 'active', p.active,
        'is_me', p.auth_email = lower(auth.email()),
        'member_active', exists (select 1 from mirror.organization_members m where m.organization_id = v_owner and m.auth_email = p.auth_email and m.active),
        'added_at', p.added_at,
        'added_by', coalesce((select m.name from mirror.organization_members m where m.organization_id = v_owner and m.auth_email = p.added_by limit 1), p.added_by),
        'removed_at', p.removed_at,
        'removed_by', coalesce((select m.name from mirror.organization_members m where m.organization_id = v_owner and m.auth_email = p.removed_by limit 1), p.removed_by))
      order by p.active desc, p.name) from mirror.platform_admins p), '[]'::jsonb));
end $$;

-- add (or put back) / remove one platform admin: { email, name, active }
create or replace function public.mirror_platform_admin_save(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = mirror, public as $$
declare
  v_owner uuid; v_email text := lower(trim(coalesce(p ->> 'email', ''))); v_active boolean := coalesce((p ->> 'active')::boolean, true);
  v_name text; v_row mirror.platform_admins;
begin
  if not coalesce(mirror.can_edit_platform_admins(), false) then
    raise exception 'Only the 2nd Chance main admin can change who is a platform admin.' using errcode = '42501';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter their full email address.' using errcode = '22023'; end if;
  select id into v_owner from mirror.organizations where is_platform_owner;
  select * into v_row from mirror.platform_admins where auth_email = v_email;

  if v_active then
    select m.name into v_name from mirror.organization_members m where m.organization_id = v_owner and m.auth_email = v_email and m.active;
    if not found then
      raise exception 'Add them as an active member of 2nd Chance Housing first (in the list above), then add them here.' using errcode = '22023';
    end if;
    v_name := coalesce(nullif(trim(p ->> 'name'), ''), v_name);
    if v_row.active then return public.mirror_platform_admins(); end if;   -- already on the list
    insert into mirror.platform_admins (auth_email, name, active, added_at, added_by) values (v_email, v_name, true, now(), lower(auth.email()))
      on conflict (auth_email) do update set name = excluded.name, active = true, added_at = now(), added_by = excluded.added_by,
        removed_at = null, removed_by = null;
    perform mirror.audit(null, v_owner, 'platform_admin', 'platform_admin_add', 'organization', 'platform_admins', v_email, null);
  else
    if not coalesce(v_row.active, false) then raise exception 'They are not on the list.' using errcode = '22023'; end if;
    if v_email = lower(auth.email()) then   -- the main admin removing themself would leave nobody able to change the list
      raise exception 'You cannot remove yourself from the list.' using errcode = '22023';
    end if;
    if (select count(*) from mirror.platform_admins where active) <= 1 then
      raise exception 'There must always be at least one platform admin.' using errcode = '22023';
    end if;
    update mirror.platform_admins set active = false, removed_at = now(), removed_by = lower(auth.email()) where auth_email = v_email;
    perform mirror.audit(null, v_owner, 'platform_admin', 'platform_admin_remove', 'organization', 'platform_admins', v_email, null);
  end if;
  return public.mirror_platform_admins();
end $$;

revoke all on function public.mirror_platform_admins(), public.mirror_platform_admin_save(jsonb) from public, anon;
grant execute on function public.mirror_platform_admins(), public.mirror_platform_admin_save(jsonb) to authenticated, service_role;
