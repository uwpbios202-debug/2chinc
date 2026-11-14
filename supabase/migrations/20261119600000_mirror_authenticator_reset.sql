-- The Human Mirror P2-11 (handoff step 17, the first Phase N step): an authenticator reset for coordinators, above all those outside
-- 2nd Chance (a Navigator's business and other organizations), who until now had no way back in after losing their phone.
--
-- Rules
--   * Who may reset: an organization's own admin (org_admin, with their authenticator code) for a member of THEIR organization, or a
--     2nd Chance platform admin for a member of any organization. Never yourself (that would let a stolen sign-in drop the second step).
--   * An organization's admin may reset only a plain Mirror sign-in: not anyone who also signs in to 2nd Chance as admin, office staff,
--     field staff, leasing agent or Housing Navigator, not a 2nd Chance member or platform admin, and not someone who is also a member of
--     another organization. Those resets are for 2nd Chance only ("Only 2nd Chance can reset this sign-in").
--   * A platform admin may reset anyone except a 2nd Chance portal admin (portal_admins).
--   * The admin first confirms who the person is (by phone or in person, never only by email) and writes why. The reset removes the
--     person's authenticator and signs them out everywhere; at their next sign-in (emailed code) they set up a new authenticator app.
--   * At most 5 resets a day per admin. Every reset is in the organization's audit log (who, when, whose, why). No email is sent.
-- The database can remove factors itself (postgres has the privileges on auth.mfa_factors and auth.sessions; their challenges, refresh
-- tokens and sign-in claims go with them by their own foreign keys). Nothing about anyone's sign-in changes unless an admin presses Reset.

-- Why this caller may not reset this member of this organization (null = may).
create or replace function mirror.authenticator_reset_refusal(p_org uuid, p_email text) returns text
language plpgsql stable security definer set search_path = mirror, public as $$
declare v_email text := lower(trim(p_email)); v_platform boolean := coalesce(mirror.is_platform_admin(), false);
begin
  if not coalesce(mirror.signed_in_member_ok(), false) then return 'Enter your authenticator code first.'; end if;
  if not (v_platform or coalesce(mirror.my_role(p_org) = 'org_admin', false)) then return 'Organization admins only.'; end if;
  if v_email = lower(auth.email()) then return 'You cannot reset your own authenticator. Ask another admin, or call 2nd Chance.'; end if;
  if not exists (select 1 from mirror.organization_members m where m.organization_id = p_org and m.auth_email = v_email) then
    return 'That person is not a member of this organization.';
  end if;
  if exists (select 1 from public.portal_admins where lower(email) = v_email) then return 'This sign-in is reset only in Supabase by the 2nd Chance main admin.'; end if;
  if v_platform then return null; end if;
  if exists (select 1 from public.condo_staff where lower(email) = v_email)
     or exists (select 1 from public.field_staff where lower(email) = v_email)
     or exists (select 1 from public.lease_agents where lower(email) = v_email)
     or exists (select 1 from public.navigators where lower(email) = v_email)
     or exists (select 1 from mirror.platform_admins p where p.auth_email = v_email)
     or exists (select 1 from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id
                where m.auth_email = v_email and (o.is_platform_owner or m.organization_id <> p_org)) then
    return 'Only 2nd Chance can reset this sign-in. Call (262) 236-5443.';
  end if;
  return null;
end $$;

-- For the admin page: each member's authenticator state and whether this caller may reset it.
create or replace function public.mirror_admin_authenticators(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
begin
  if not mirror.can_manage_members(p_org) then raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id,
      'has_authenticator', exists (select 1 from auth.users u join auth.mfa_factors f on f.user_id = u.id
                                   where lower(u.email) = m.auth_email and f.status = 'verified'),
      'refusal', mirror.authenticator_reset_refusal(p_org, m.auth_email),
      'last_reset_at', (select max(a.at) from mirror.audit_logs a where a.organization_id = p_org and a.action = 'authenticator_reset'
                        and a.row_id = m.id::text)))
    from mirror.organization_members m where m.organization_id = p_org), '[]'::jsonb);
end $$;

-- The reset itself.
create or replace function public.mirror_admin_authenticator_reset(p_org uuid, p_member uuid, p_reason text, p_confirmed boolean) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare m mirror.organization_members; v_why text; v_user uuid; v_factors int := 0; v_sessions int := 0; v_role text;
begin
  select * into m from mirror.organization_members where id = p_member and organization_id = p_org;
  if m.id is null then raise exception 'That person is not a member of this organization.' using errcode = '42501'; end if;
  v_why := mirror.authenticator_reset_refusal(p_org, m.auth_email);
  if v_why is not null then raise exception '%', v_why using errcode = '42501'; end if;
  if coalesce(p_confirmed, false) is not true then
    raise exception 'First confirm who they are, by phone or in person (never only by email), then tick the box.' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write why, for example: lost their phone.' using errcode = '22023'; end if;
  if length(p_reason) > 300 then raise exception 'Keep the reason to 300 characters.' using errcode = '22023'; end if;
  if (select count(*) from mirror.audit_logs where actor_email = lower(auth.email()) and action = 'authenticator_reset'
        and at > now() - interval '1 day') >= 5 then
    raise exception 'That is 5 resets today. Call 2nd Chance at (262) 236-5443 if you need more.';
  end if;
  select id into v_user from auth.users where lower(email) = m.auth_email;
  if v_user is not null then
    delete from auth.mfa_factors where user_id = v_user;
    get diagnostics v_factors = row_count;
    delete from auth.sessions where user_id = v_user;
    get diagnostics v_sessions = row_count;
  end if;
  v_role := case when coalesce(mirror.is_platform_admin(), false) and coalesce(mirror.my_role(p_org), '') <> 'org_admin' then 'platform_admin' else 'org_admin' end;
  perform mirror.audit(null, p_org, v_role, 'authenticator_reset', 'organization', 'organization_members', m.id::text,
                       left(btrim(p_reason), 300));
  return jsonb_build_object('name', m.name, 'authenticators_removed', v_factors, 'signed_out_devices', v_sessions, 'had_signed_in', v_user is not null);
end $$;

revoke all on function mirror.authenticator_reset_refusal(uuid, text) from public, anon, authenticated;
grant execute on function mirror.authenticator_reset_refusal(uuid, text) to service_role;
revoke all on function public.mirror_admin_authenticators(uuid), public.mirror_admin_authenticator_reset(uuid, uuid, text, boolean) from public, anon;
grant execute on function public.mirror_admin_authenticators(uuid), public.mirror_admin_authenticator_reset(uuid, uuid, text, boolean) to authenticated, service_role;
