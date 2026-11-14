-- The Human Mirror, Phase 2 fix 5 of 15 (Stephen, 11/13/2026): the Mirror ignored session_fresh().
-- The rest of the site treats a remembered device past its idle or maximum days (session_idle_days_<role> / session_max_days_<role>,
-- or signed out everywhere) as signed out. The Mirror's own gates only checked that an email was present, so an expired device kept
-- working there. Now every Mirror identity gate also requires public.session_fresh():
--   mirror.me() (the person), mirror.signed_in_member_ok() (coordinators and admins; also used by my_role and is_platform_admin),
--   mirror.allowed() (the data gate, which reads the email itself), public.mirror_who_looked(), and public.mirror_whoami(), which now
--   answers signed_in = false, expired = true, so the existing pages send the person to the sign-in page for a new code.
-- Bodies below are the LIVE definitions of 11/13/2026 with only the session lines added. Shared session functions are not changed (D-22).
-- No table is created (no new grants); create or replace keeps each function's grants.

CREATE OR REPLACE FUNCTION mirror.me()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid;
begin
  if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not coalesce(public.session_fresh(), false) then raise exception 'Your sign-in on this device has expired. Please sign in again.' using errcode = '42501'; end if;
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  select id into v from mirror.individuals where auth_email = lower(auth.email());
  if v is null then raise exception 'There is no Mirror for this sign-in.' using errcode = '42501'; end if;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION mirror.signed_in_member_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
  select auth.email() is not null and coalesce(auth.jwt() ->> 'aal', '') = 'aal2' and not coalesce(public.autopay_view_as_session(), true)
    and coalesce(public.session_fresh(), false);
$function$;

CREATE OR REPLACE FUNCTION mirror.allowed(p_individual uuid, p_category text, p_action text, p_org uuid DEFAULT NULL::uuid, p_table text DEFAULT NULL::text, p_row text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_email text := lower(auth.email());
  v_sensitive boolean := p_category not in ('general', 'safety_flag', 'organization', 'audit');
  v_member boolean := false;
  v_org uuid;
  v_role text;
  v_probe boolean := p_table is not distinct from '_probe';   -- quiet: a permission probe, never logged
  m record;
  p mirror.role_permissions;
begin
  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'Sign-in required.');
  end if;
  if not coalesce(public.session_fresh(), false) then
    return jsonb_build_object('ok', false, 'reason', 'Your sign-in on this device has expired. Please sign in again.');
  end if;
  if public.autopay_view_as_session() then
    if not v_probe then perform mirror.audit(p_individual, p_org, 'view_as', 'refused', p_category, p_table, p_row, 'view_as'); end if;
    return jsonb_build_object('ok', false, 'reason', 'Not available while viewing as someone else.');
  end if;

  -- the person themself
  if exists (select 1 from mirror.individuals i where i.id = p_individual and i.auth_email = v_email) then
    select * into p from mirror.role_permissions where role = 'self' and category = p_category and action = p_action;
    if found then return jsonb_build_object('ok', true, 'role', 'self'); end if;
    return jsonb_build_object('ok', false, 'role', 'self', 'reason', 'Not allowed.');
  end if;

  -- a member of an organization that works with the person (active link only)
  for m in
    select om.role, om.organization_id
    from mirror.organization_members om
    join mirror.organizations o on o.id = om.organization_id and o.active
    join mirror.organization_individuals oi on oi.organization_id = om.organization_id and oi.individual_id = p_individual and oi.status = 'active'
    where om.auth_email = v_email and om.active and (p_org is null or om.organization_id = p_org)
    order by case om.role when 'org_admin' then 1 when 'coordinator' then 2 else 3 end
  loop
    v_member := true;
    if v_org is null then v_org := m.organization_id; v_role := m.role; end if;
    if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
      if not v_probe then perform mirror.audit(p_individual, m.organization_id, m.role, 'refused', p_category, p_table, p_row, 'no_authenticator'); end if;
      return jsonb_build_object('ok', false, 'role', m.role, 'reason', 'Enter your authenticator code first.');
    end if;
    select * into p from mirror.role_permissions where role = m.role and category = p_category and action = p_action;
    continue when not found;
    if p.needs_consent and not exists (
         select 1 from mirror.consents c
         where c.individual_id = p_individual and c.organization_id = m.organization_id and c.category = p_category
           and c.revoked_at is null and (c.expires_on is null or c.expires_on >= current_date)
           and (p_action = 'view' or c.access = 'edit')) then
      continue;
    end if;
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit(p_individual, m.organization_id, m.role, p_action, p_category, p_table, p_row, null); end if;
    end if;
    return jsonb_build_object('ok', true, 'role', m.role, 'organization_id', m.organization_id);
  end loop;

  if v_member then
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit(p_individual, v_org, v_role, 'refused', p_category, p_table, p_row, 'no_consent'); end if;
    end if;
    return jsonb_build_object('ok', false, 'reason', 'The person has not shared this with your organization.');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'Not allowed.');
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_who_looked()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_id uuid;
begin
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  if not coalesce(public.session_fresh(), false) then raise exception 'Your sign-in on this device has expired. Please sign in again.' using errcode = '42501'; end if;
  select id into v_id from mirror.individuals where auth_email = lower(auth.email());
  if v_id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'at', a.at,
      'organization', o.name,
      'who', coalesce(om.name, case a.actor_role when 'view_as' then 'Office (view as)' else 'Someone at ' || coalesce(o.name, 'an organization') end),
      'role', a.actor_role,
      'action', a.action,
      'category', a.category) order by a.at desc)
    from (select * from mirror.audit_logs where individual_id = v_id and coalesce(actor_email, '') <> lower(auth.email())
          order by at desc limit 500) a
    left join mirror.organizations o on o.id = a.organization_id
    left join mirror.organization_members om on om.organization_id = a.organization_id and om.auth_email = a.actor_email), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_whoami()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_email text := lower(auth.email());
  v_aal text := coalesce(auth.jwt() ->> 'aal', '');
  v_person jsonb;
  v_member jsonb;
  v_invites int := 0;
begin
  if v_email is null then return jsonb_build_object('signed_in', false); end if;
  -- a remembered device past its idle or maximum days counts as signed out: the page asks for a new code
  if not coalesce(public.session_fresh(), false) then return jsonb_build_object('signed_in', false, 'expired', true); end if;
  select jsonb_build_object('id', i.id, 'preferred_name', i.preferred_name) into v_person
    from mirror.individuals i where i.auth_email = v_email;
  select jsonb_agg(jsonb_build_object('organization_id', o.id, 'organization', o.name, 'role', m.role, 'name', m.name) order by o.name) into v_member
    from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active
    where m.auth_email = v_email and m.active;
  if v_person is not null then
    select count(*) into v_invites from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
     where oi.individual_id = (v_person ->> 'id')::uuid and oi.status = 'invited';
  end if;
  return jsonb_build_object(
    'signed_in', true,
    'email', v_email,
    'aal', v_aal,
    'view_as', public.autopay_view_as_session(),
    'person', v_person,
    'memberships', coalesce(v_member, '[]'::jsonb),
    'needs_authenticator', v_member is not null and v_aal <> 'aal2',
    'invitations', v_invites,
    'signin_enabled', coalesce((select value from public.portal_settings where key = 'mirror_signin_enabled'), 'off') = 'on');
end $function$;
