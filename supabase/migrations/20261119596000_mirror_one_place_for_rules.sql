-- The Human Mirror P2-13 (Phase 10 step 29; Stephen 11/13/2026 "go to phase 10"): one place for the access rules.
-- Before: mirror.role_permissions held what each role may see and change per topic, but several functions also decided by naming a role
-- in code ("org_admin", "coordinator"): who may open the workspace, manage members and services, read the organization's audit log,
-- confirm a need or a milestone, use the conversation guide. Changing the table did not change those.
-- Now (D-41): every such decision asks the table. Two capabilities join it: 'workspace' (view: work with the organization's people) and
-- 'confirm' (edit: confirm a need met or a milestone); 'organization' (edit) already meant managing members and services, 'audit'
-- (view) the organization's audit log. Helpers mirror.role_can(role, category, action) and mirror.i_can(org, category, action).
-- Behaviour is unchanged: the rows added give exactly the roles that had these powers (org_admin, coordinator). Role NAMES still appear
-- where they are identities, not permissions: the audit label, role ordering, "keep at least one organization admin", the role list a
-- member may be given, and a Navigator becoming the admin of their own business.
-- The function bodies below are the live ones (11/13/2026) with only the role checks changed.

alter table mirror.role_permissions drop constraint role_permissions_category_check;
alter table mirror.role_permissions add constraint role_permissions_category_check check (category = any (array['general', 'health',
  'mental_health', 'safety', 'safety_flag', 'legal', 'immigration', 'financial', 'documents', 'organization', 'audit', 'workspace', 'confirm']));
insert into mirror.role_permissions (role, category, action) values
  ('org_admin', 'workspace', 'view'), ('coordinator', 'workspace', 'view'),
  ('org_admin', 'confirm', 'edit'), ('coordinator', 'confirm', 'edit')
on conflict do nothing;

-- does this role have this permission? (null role: no)
create or replace function mirror.role_can(p_role text, p_category text, p_action text) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select p_role is not null and exists (select 1 from mirror.role_permissions p where p.role = p_role and p.category = p_category and p.action = p_action);
$$;
-- may I (signed in, authenticator, active member of this active organization) do this here?
create or replace function mirror.i_can(p_org uuid, p_category text, p_action text) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.role_can(mirror.my_role(p_org), p_category, p_action), false);
$$;
revoke all on function mirror.role_can(text, text, text), mirror.i_can(uuid, text, text) from public, anon, authenticated;
grant execute on function mirror.role_can(text, text, text), mirror.i_can(uuid, text, text) to service_role;

CREATE OR REPLACE FUNCTION mirror.coordinates(p_org uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
  select mirror.i_can(p_org, 'workspace', 'view');   -- no role = no (never null)
$function$;

CREATE OR REPLACE FUNCTION mirror.can_manage_members(p_org uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
  select coalesce(mirror.is_platform_admin(), false) or mirror.i_can(p_org, 'organization', 'edit');   -- no role = no (never null)
$function$;

CREATE OR REPLACE FUNCTION mirror.platform_outside(p_org uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
  select coalesce(mirror.is_platform_admin(), false) and not mirror.i_can(p_org, 'organization', 'edit');
$function$;

CREATE OR REPLACE FUNCTION mirror.authenticator_reset_refusal(p_org uuid, p_email text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_email text := lower(trim(p_email)); v_platform boolean := coalesce(mirror.is_platform_admin(), false);
begin
  if not coalesce(mirror.signed_in_member_ok(), false) then return 'Enter your authenticator code first.'; end if;
  if not (v_platform or mirror.i_can(p_org, 'organization', 'edit')) then return 'Organization admins only.'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION mirror.conv_member(p_org uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_role text;
begin
  if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  select om.role into v_role from mirror.organization_members om join mirror.organizations o on o.id = om.organization_id and o.active
   where om.organization_id = p_org and om.auth_email = lower(auth.email()) and om.active and mirror.role_can(om.role, 'workspace', 'view');
  if v_role is null then raise exception 'You are not a coordinator of this organization.' using errcode = '42501'; end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then raise exception 'Enter your authenticator code first.' using errcode = '42501'; end if;
  return v_role;
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_admin_orgs()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_admin boolean := mirror.is_platform_admin();
begin
  if not v_admin and not exists (select 1 from mirror.organization_members m where m.auth_email = lower(auth.email()) and m.active and mirror.role_can(m.role, 'organization', 'edit'))
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
      from mirror.organizations o where v_admin or mirror.i_can(o.id, 'organization', 'edit')), '[]'::jsonb),
    'navigators', case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'name', n.name, 'status', n.status) order by n.name)
      from public.navigators n where n.status in ('preview', 'pilot', 'active')), '[]'::jsonb) else '[]'::jsonb end);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_need_status(p_id uuid, p_status text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  n mirror.needs;
  g jsonb;
  v_from text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if coalesce(p_status, '') not in ('identified', 'planning', 'in_progress', 'obtained', 'verified', 'no_longer_needed') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) > 1000 then raise exception 'The note is too long (1,000 letters at most).' using errcode = '22023'; end if;
  select * into n from mirror.needs where id = p_id;
  if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(n.individual_id, n.category, 'edit', null, 'needs', n.id::text);
  if p_status = n.status then return mirror.need_json(n); end if;
  if p_status = 'verified' then
    if not mirror.role_can(g ->> 'role', 'confirm', 'edit') then
      raise exception 'A need is verified by someone from an organization you work with, who confirms it was met.' using errcode = '42501';
    end if;
    if n.status <> 'obtained' then raise exception 'Mark the need as obtained first.' using errcode = '22023'; end if;
  end if;
  v_from := n.status;
  update mirror.needs set status = p_status,
    verified_at = case when p_status = 'verified' then now() end,
    verified_by = case when p_status = 'verified' then lower(auth.email()) end
   where id = n.id returning * into n;
  insert into mirror.need_events (need_id, by_email, by_role, from_status, to_status, note)
  values (n.id, lower(auth.email()), g ->> 'role', v_from, p_status, v_note);
  return mirror.need_json(n);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_milestone_confirm(p_id uuid, p_confirm boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare m mirror.milestones; gate jsonb;
begin
  select * into m from mirror.milestones where id = p_id;
  if not found then raise exception 'That milestone is not available.' using errcode = 'P0002'; end if;
  gate := mirror.require(m.individual_id, m.category, 'edit', null, 'milestones', m.id::text);
  if p_confirm and not mirror.role_can(gate ->> 'role', 'confirm', 'edit') then
    raise exception 'A milestone is confirmed by someone from an organization you work with.' using errcode = '42501';
  end if;
  update mirror.milestones set verified_at = case when p_confirm then now() end, verified_by = case when p_confirm then lower(auth.email()) end
   where id = m.id returning * into m;
  return mirror.milestone_json(m);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_org_audit(p_org uuid, p_before bigint DEFAULT NULL::bigint, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_rows jsonb;
begin
  if not mirror.i_can(p_org, 'audit', 'view') then
    raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'at', a.at,
      'who', coalesce(om.name, case when a.actor_role = 'self' then 'The person' when a.actor_role = 'view_as' then 'Office (view as)'
                                    else 'Someone no longer listed' end),
      'role', a.actor_role, 'action', a.action, 'category', a.category, 'what', a.table_name, 'reason', a.reason,
      'person_id', case when a.individual_id is not null and mirror.known_to_org(a.individual_id, p_org) then a.individual_id end,
      'person', case when a.individual_id is null then null when mirror.known_to_org(a.individual_id, p_org) then i.preferred_name
                     else 'A person not on your list' end) order by a.id desc), '[]'::jsonb)
    into v_rows
    from (select * from mirror.audit_logs x where x.organization_id = p_org and (p_before is null or x.id < p_before)
            and (p_individual is null or x.individual_id = p_individual) order by x.id desc limit 100) a
    left join mirror.organization_members om on om.organization_id = p_org and om.auth_email = a.actor_email
    left join mirror.individuals i on i.id = a.individual_id;
  perform mirror.audit(p_individual, p_org, 'org_admin', 'view', 'audit', 'audit_logs', null);
  return jsonb_build_object('rows', v_rows, 'more', jsonb_array_length(v_rows) = 100);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_services(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare v_admin boolean;
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  v_admin := mirror.i_can(p_org, 'organization', 'edit');
  return jsonb_build_object('can_manage', v_admin,
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'description', s.description,
        'dimension_key', s.dimension_key, 'area', (select d.title from mirror.dimensions d where d.key = s.dimension_key),
        'private', s.category <> 'general', 'active', s.active,
        'has_enrollments', exists (select 1 from mirror.service_enrollments e where e.service_id = s.id),
        -- counts only over enrollments this viewer may see (quiet probe; a count is not a look at a person)
        'getting_it', (select count(*) from mirror.service_enrollments e where e.service_id = s.id and e.status = 'active'
                        and coalesce((mirror.allowed(e.individual_id, e.category, 'view', p_org, '_probe', null) ->> 'ok')::boolean, false)),
        'on_hold', (select count(*) from mirror.service_enrollments e where e.service_id = s.id and e.status = 'paused'
                        and coalesce((mirror.allowed(e.individual_id, e.category, 'view', p_org, '_probe', null) ->> 'ok')::boolean, false)))
        order by s.active desc, lower(s.name)) from mirror.services s where s.organization_id = p_org), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_admin_authenticator_reset(p_org uuid, p_member uuid, p_reason text, p_confirmed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
  v_role := case when mirror.platform_outside(p_org) then 'platform_admin' else 'org_admin' end;
  perform mirror.audit(null, p_org, v_role, 'authenticator_reset', 'organization', 'organization_members', m.id::text,
                       left(btrim(p_reason), 300));
  return jsonb_build_object('name', m.name, 'authenticators_removed', v_factors, 'signed_out_devices', v_sessions, 'had_signed_in', v_user is not null);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_service_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_desc text := nullif(btrim(coalesce(p ->> 'description', '')), '');
  v_dim text := nullif(p ->> 'dimension_key', '');
  v_active boolean := coalesce((p ->> 'active')::boolean, true);
  s mirror.services;
begin
  if v_id is not null then
    select * into s from mirror.services where id = v_id;
    if not found then raise exception 'That service is not available.' using errcode = 'P0002'; end if;
    v_org := s.organization_id;
  end if;
  if v_org is null or not mirror.coordinates(v_org) or not mirror.i_can(v_org, 'organization', 'edit') then
    raise exception 'Organization admins add and change services (with your authenticator code).' using errcode = '42501';
  end if;
  if length(v_name) = 0 then raise exception 'Give the service a name.' using errcode = '22023'; end if;
  if length(v_name) > 120 then raise exception 'Please keep the name to 120 letters; add more in the description.' using errcode = '22023'; end if;
  if length(coalesce(v_desc, '')) > 1000 then raise exception 'The description is too long (1,000 letters at most).' using errcode = '22023'; end if;
  if v_dim is not null and not exists (select 1 from mirror.dimensions d where d.key = v_dim) then
    raise exception 'Unknown area of life.' using errcode = '22023';
  end if;
  if v_id is null then
    insert into mirror.services (organization_id, name, description, dimension_key, category, active, created_by)
    values (v_org, v_name, v_desc, v_dim, coalesce(mirror.dimension_category(v_dim), 'general'), v_active, lower(auth.email()))
    returning * into s;
  else
    if s.dimension_key is distinct from v_dim and exists (select 1 from mirror.service_enrollments e where e.service_id = s.id) then
      raise exception 'People are enrolled in this service, so its area of life stays as it is. Add a new service instead.' using errcode = '22023';
    end if;
    update mirror.services set name = v_name, description = v_desc, dimension_key = v_dim,
      category = coalesce(mirror.dimension_category(v_dim), 'general'), active = v_active
     where id = s.id returning * into s;
  end if;
  perform mirror.audit(null, v_org, 'org_admin', 'service_save', 'organization', 'services', s.id::text);
  return jsonb_build_object('id', s.id, 'name', s.name, 'active', s.active);
exception when unique_violation then
  raise exception 'Your organization already has a service with that name.' using errcode = '23505';
end $function$;
