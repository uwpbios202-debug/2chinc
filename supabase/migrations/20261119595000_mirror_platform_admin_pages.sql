-- The Human Mirror P2-08 (Phase 2 deep-dive fix 8; Stephen 11/13/2026 "then go"): the platform admin pages still missing from the site
-- map's /mirror/admin/ (users, roles, teams, consent, audit, email, configuration, security, data management). Organizations, members
-- and platform admins were built in Phase 2 (T2.5); the organization's own audit view in T8.1 (P2-07). This adds, for 2nd Chance
-- platform admins only (mirror.is_platform_admin: on the list, member of 2nd Chance, authenticator):
--   1. public.mirror_platform_overview(): counts and rules only, never a person's name or answers: people and members (by role, with or
--      without an authenticator), organizations, the role rules (role_permissions, read only), sharing choices per organization / topic /
--      access, email choices and Mirror emails in the outbox, the Mirror settings, and deletion requests waiting (dates only).
--   2. public.mirror_platform_audit(org, before): every organization's audit log, newest first, 100 at a time (P2-07, platform half).
--      Members are shown by name, never by email; a person is never named, only a short code that is the same on every row for the
--      same person (to follow one case without knowing who it is).
--   Both reads are written to the audit log themselves.
-- Rules (D-40, defaults chosen by Claude): read only (settings, rules and the sign-in switch are changed by Stephen's decision, not on
-- this page); no "teams" inside an organization (an organization is the team; its members list is on Organizations and members);
-- the deletion run itself stays Phase 2 fix 9. No new tables.

create or replace function public.mirror_platform_overview() returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v jsonb;
begin
  if not coalesce(mirror.is_platform_admin(), false) then
    raise exception '2nd Chance platform admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'people', jsonb_build_object(
      'total', (select count(*) from mirror.individuals),
      'with_sign_in_email', (select count(*) from mirror.individuals where auth_email is not null),
      'safety_mode', (select count(*) from mirror.individuals where safety_sensitive),
      'deletion_requested', (select count(*) from mirror.individuals where deletion_requested_at is not null)),
    'members', coalesce((select jsonb_agg(jsonb_build_object('role', z.role, 'active', z.active, 'with_authenticator', z.mfa) order by z.role) from (
        select m.role, count(*) filter (where m.active) as active,
               count(*) filter (where m.active and exists (select 1 from auth.users u join auth.mfa_factors f on f.user_id = u.id
                                 where lower(u.email) = m.auth_email and f.status = 'verified')) as mfa
          from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active group by m.role) z), '[]'::jsonb),
    'organizations', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'kind', o.kind, 'active', o.active,
        'members', (select count(*) from mirror.organization_members m where m.organization_id = o.id and m.active),
        'people', (select count(*) from mirror.organization_individuals oi where oi.organization_id = o.id and oi.status = 'active'))
        order by o.is_platform_owner desc, o.name) from mirror.organizations o), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('role', p.role, 'category', p.category, 'action', p.action) order by p.role, p.category, p.action)
        from mirror.role_permissions p), '[]'::jsonb),
    'sharing', coalesce((select jsonb_agg(jsonb_build_object('organization', z.name, 'topic', z.category, 'access', z.access, 'people', z.n,
        'ending_in_30_days', z.ending) order by z.name, z.category, z.access) from (
        select o.name, c.category, c.access, count(distinct c.individual_id) as n,
               count(distinct c.individual_id) filter (where c.expires_on between current_date and current_date + 30) as ending
          from mirror.consents c join mirror.organizations o on o.id = c.organization_id
         where c.revoked_at is null and (c.expires_on is null or c.expires_on >= current_date)
         group by o.name, c.category, c.access) z), '[]'::jsonb),
    'email', jsonb_build_object(
      'turned_off', jsonb_build_object(
        'referral', (select count(*) from mirror.profiles p where p.notification_prefs ->> 'referral' = 'false'),
        'appointment', (select count(*) from mirror.profiles p where p.notification_prefs ->> 'appointment' = 'false'),
        'action', (select count(*) from mirror.profiles p where p.notification_prefs ->> 'action' = 'false')),
      'outbox', coalesce((select jsonb_agg(jsonb_build_object('kind', z.kind, 'waiting', z.waiting, 'sent', z.sent, 'failed', z.failed) order by z.kind) from (
          select e.kind, count(*) filter (where e.sent_at is null and e.error is null) as waiting, count(*) filter (where e.sent_at is not null) as sent,
                 count(*) filter (where e.sent_at is null and e.error is not null) as failed
            from public.email_outbox e where e.kind like 'mirror%' group by e.kind) z), '[]'::jsonb)),
    'settings', coalesce((select jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value) order by s.key)
        from public.portal_settings s where s.key like 'mirror%'), '[]'::jsonb),
    'deletions', coalesce((select jsonb_agg(jsonb_build_object('code', left(md5(i.id::text), 6), 'requested_on', (i.deletion_requested_at)::date,
        'due_on', (i.deletion_requested_at + interval '30 days')::date) order by i.deletion_requested_at)
        from mirror.individuals i where i.deletion_requested_at is not null), '[]'::jsonb),
    'today', current_date)
  into v;
  perform mirror.audit(null, null, 'platform_admin', 'view', 'organization', 'platform_overview', null);
  return v;
end $$;

-- every organization's audit log, newest first, 100 at a time; p_org narrows to one organization
create or replace function public.mirror_platform_audit(p_org uuid default null, p_before bigint default null) returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v_rows jsonb;
begin
  if not coalesce(mirror.is_platform_admin(), false) then
    raise exception '2nd Chance platform admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'at', a.at, 'organization', o.name,
      'who', coalesce(om.name, pa.name, case when a.actor_role = 'self' then 'The person' when a.actor_role = 'view_as' then 'Office (view as)'
                                              else 'Someone no longer listed' end),
      'role', a.actor_role, 'action', a.action, 'category', a.category, 'what', a.table_name, 'reason', a.reason,
      'person', case when a.individual_id is not null then 'Person ' || left(md5(a.individual_id::text), 6) end) order by a.id desc), '[]'::jsonb)
    into v_rows
    from (select * from mirror.audit_logs x where (p_org is null or x.organization_id = p_org) and (p_before is null or x.id < p_before)
            order by x.id desc limit 100) a
    left join mirror.organizations o on o.id = a.organization_id
    left join mirror.organization_members om on om.organization_id = a.organization_id and om.auth_email = a.actor_email
    left join mirror.platform_admins pa on pa.auth_email = a.actor_email and om.name is null;
  perform mirror.audit(null, p_org, 'platform_admin', 'view', 'audit', 'audit_logs', null);
  return jsonb_build_object('rows', v_rows, 'more', jsonb_array_length(v_rows) = 100);
end $$;

revoke all on function public.mirror_platform_overview(), public.mirror_platform_audit(uuid, bigint) from public, anon;
grant execute on function public.mirror_platform_overview(), public.mirror_platform_audit(uuid, bigint) to authenticated, service_role;
