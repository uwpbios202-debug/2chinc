-- The Human Mirror: making the final privacy page true before it is published (legal's text, Stephen 11/14/2026: "build all 3 first").
--   1. "If you are in danger, tell your coordinator or call us. We will hide your Mirror from everyone right away while the 30 days run."
--      mirror.individuals.hidden_at. Hiding ends every organization's link at once (an organization reaches a person only through an
--      active link, mirror.allowed), takes the person off every People list, shows them in organization audit logs only as "A person
--      not on your list", and stops anyone restarting, re-inviting or re-adding them. The person still signs in and sees their own Mirror.
--        * The person: Settings, "Hide my Mirror from everyone now" (mirror_my_hide) and "Show it to organizations again" (mirror_my_unhide;
--          old links stay ended, organizations can invite them again).
--        * A coordinator of an organization they work with: "Hide their Mirror now" on the People list (mirror_person_hide), after the
--          person asked (in person or by phone), with a reason. It only hides; it never asks for deletion (a coordinator must not be able
--          to have someone's Mirror deleted).
--        * 2nd Chance (platform admin), when the person calls: by email (mirror_platform_hide), optionally recording the deletion request
--          the person made on the phone.
--      Every hide is in the audit log. Hiding does not change a deletion request, and keeping the Mirror does not end the hiding.
--   2. "The Mirror is for adults 18 and older." A birth year that makes the person under 18 (this year minus the birth year < 18) is
--      refused wherever it is entered (trigger on mirror.individuals). Birth year stays optional.
--   3. "If we change how we use or share your information, we will tell you in the Mirror the next time you sign in, before the change
--      starts." portal_settings.mirror_change_notice (empty = none) set by the 2nd Chance main admin (mirror_admin_change_notice_set, the
--      start date must be after today); mirror_whoami returns it until the person presses "I've read it" (mirror_notice_seen,
--      mirror.profiles.notice_seen); every Mirror page shows it at the top.
-- New columns only (no new table). No email is sent.

alter table mirror.individuals add column hidden_at timestamptz;
alter table mirror.profiles add column notice_seen text;
insert into portal_settings (key, value) values ('mirror_change_notice', '') on conflict (key) do nothing;

-- 2. adults only
create or replace function mirror.adults_only() returns trigger
language plpgsql set search_path = mirror as $$
begin
  if new.birth_year is not null and new.birth_year > extract(year from (now() at time zone 'America/Chicago'))::int - 18 then
    raise exception 'The Mirror is for adults 18 and older. For someone under 18: call or text 988, or call 2nd Chance at (262) 236-5443.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger individuals_adults_only before insert or update of birth_year on mirror.individuals
  for each row execute function mirror.adults_only();

-- 1. hiding
create or replace function mirror.hide_individual(p_individual uuid, p_org uuid, p_role text, p_reason text) returns void
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  update mirror.individuals set hidden_at = coalesce(hidden_at, now()), updated_at = now() where id = p_individual;
  update mirror.organization_individuals set status = 'ended', ended_on = current_date, updated_at = now()
   where individual_id = p_individual and status <> 'ended';
  perform mirror.audit(p_individual, p_org, p_role, 'hide', 'general', 'individuals', null, nullif(left(btrim(coalesce(p_reason, '')), 300), ''));
end $$;

create or replace function public.mirror_my_hide() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  perform mirror.hide_individual(v, null, 'self', null);
  return (select jsonb_build_object('hidden_at', hidden_at) from mirror.individuals where id = v);
end $$;

create or replace function public.mirror_my_unhide() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  update mirror.individuals set hidden_at = null, updated_at = now() where id = v and hidden_at is not null;
  if found then perform mirror.audit(v, null, 'self', 'unhide', 'general', 'individuals', null, null); end if;
  return jsonb_build_object('hidden_at', null);
end $$;

create or replace function public.mirror_person_hide(p_org uuid, p_individual uuid, p_reason text, p_confirmed boolean) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if p_org is null or not coalesce(mirror.coordinates(p_org), false) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                 and oi.status in ('invited', 'active')) then
    raise exception 'This person is not on your organization''s list.' using errcode = '42501';
  end if;
  if coalesce(p_confirmed, false) is not true then raise exception 'Only when they ask for it, in person or by phone. Then tick the box.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write a short reason, for example: asked on the phone, not safe.' using errcode = '22023'; end if;
  perform mirror.hide_individual(p_individual, p_org, mirror.my_role(p_org), p_reason);
end $$;

create or replace function public.mirror_platform_hide(p_email text, p_also_delete boolean, p_reason text, p_confirmed boolean) returns text
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid;
begin
  if not coalesce(mirror.is_platform_admin(), false) then raise exception 'Platform admins only (with your authenticator code).' using errcode = '42501'; end if;
  if coalesce(p_confirmed, false) is not true then raise exception 'First confirm it is them (by phone, video or in person), then tick the box.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write a short reason, for example: called, not safe.' using errcode = '22023'; end if;
  select id into v from mirror.individuals where auth_email = lower(trim(coalesce(p_email, '')));
  if v is null then return 'No Mirror uses that email.'; end if;
  perform mirror.hide_individual(v, null, 'platform_admin', p_reason);
  if coalesce(p_also_delete, false) then
    update mirror.individuals set deletion_requested_at = coalesce(deletion_requested_at, now()) where id = v;
    perform mirror.audit(v, null, 'platform_admin', 'delete_request', 'general', 'individuals', null, 'asked by phone');
    return 'Hidden from everyone now. Deletion asked for: it will be deleted after 30 days.';
  end if;
  return 'Hidden from everyone now.';
end $$;

-- 3. change notice
create or replace function public.mirror_notice_seen(p_id text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v_email text := lower(auth.email());
begin
  if v_email is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  insert into mirror.profiles (auth_email, notice_seen) values (v_email, left(p_id, 40))
  on conflict (auth_email) do update set notice_seen = excluded.notice_seen, updated_at = now();
end $$;

create or replace function public.mirror_admin_change_notice_set(p_text text, p_starts date) returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v jsonb;
begin
  if not (coalesce(mirror.signed_in_member_ok(), false) and exists (select 1 from public.portal_admins where lower(email) = lower(auth.email()))) then
    raise exception 'The 2nd Chance main admin only (with your authenticator code).' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_text, '')), '') is null then
    update public.portal_settings set value = '' where key = 'mirror_change_notice';
    perform mirror.audit(null, null, 'platform_admin', 'edit', 'organization', 'portal_settings', 'mirror_change_notice', 'cleared');
    return null;
  end if;
  if length(p_text) > 1000 then raise exception 'Keep the notice to 1,000 characters.' using errcode = '22023'; end if;
  if p_starts is null or p_starts <= current_date then raise exception 'Give the day the change starts. It must be after today, so people are told first.' using errcode = '22023'; end if;
  v := jsonb_build_object('id', to_char(now(), 'YYYYMMDDHH24MISS'), 'text', btrim(p_text), 'starts', p_starts);
  update public.portal_settings set value = v::text where key = 'mirror_change_notice';
  perform mirror.audit(null, null, 'platform_admin', 'edit', 'organization', 'portal_settings', 'mirror_change_notice', 'set');
  return v;
end $$;

-- mirror_my_settings: live body; NEW: hidden_at

CREATE OR REPLACE FUNCTION public.mirror_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare v uuid := mirror.me();
begin
  return jsonb_build_object(
    'person', (select jsonb_build_object('preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'birth_year', i.birth_year,
        'email', i.auth_email, 'safety_sensitive', i.safety_sensitive, 'deletion_requested_at', i.deletion_requested_at, 'hidden_at', i.hidden_at,
        'deletion_on', (i.deletion_requested_at + interval '30 days')::date)
      from mirror.individuals i where i.id = v),
    'organizations', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'kind', o.kind, 'status', oi.status, 'started_on', oi.started_on,
        'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
        'sharing', coalesce((select jsonb_object_agg(c.category, c.access) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb),
        'sharing_until', coalesce((select jsonb_object_agg(c.category, c.expires_on) from mirror.consents c          -- NEW
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.expires_on >= current_date), '{}'::jsonb),
        'sharing_detail', coalesce((select jsonb_object_agg(c.category, jsonb_build_object('method', c.method, 'at', c.granted_at,
            'by', coalesce((select m.name from mirror.organization_members m where m.organization_id = o.id and m.auth_email = c.granted_by), 'you'))) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.method <> 'online'
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb))
        order by (oi.status = 'ended'), o.name)
      from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id
      where oi.individual_id = v), '[]'::jsonb));
end $function$
;

-- mirror_people: live body; NEW: a hidden person is not listed

CREATE OR REPLACE FUNCTION public.mirror_people(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(case when mirror.known_to_org(i.id, p_org) then jsonb_build_object(
      'id', i.id, 'preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'email', i.auth_email, 'birth_year', i.birth_year,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', i.safety_sensitive)
    else jsonb_build_object(
      'id', i.id, 'preferred_name', coalesce(oi.invited_name, 'Invited person'), 'legal_name', null, 'email', i.auth_email, 'birth_year', null,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', null) end
    order by (oi.status = 'ended'), lower(case when mirror.known_to_org(i.id, p_org) then i.preferred_name else coalesce(oi.invited_name, '') end))
    from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
    where oi.organization_id = p_org and i.hidden_at is null), '[]'::jsonb);   -- hidden: not listed
end $function$
;

-- mirror_org_audit: live body; NEW: a hidden person is shown as 'A person not on your list'

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
      'person_id', case when a.individual_id is not null and i.hidden_at is null and mirror.known_to_org(a.individual_id, p_org) then a.individual_id end,
      'person', case when a.individual_id is null then null when i.hidden_at is null and mirror.known_to_org(a.individual_id, p_org) then i.preferred_name
                     else 'A person not on your list' end) order by a.id desc), '[]'::jsonb)
    into v_rows
    from (select * from mirror.audit_logs x where x.organization_id = p_org and (p_before is null or x.id < p_before)
            and (p_individual is null or x.individual_id = p_individual) order by x.id desc limit 100) a
    left join mirror.organization_members om on om.organization_id = p_org and om.auth_email = a.actor_email
    left join mirror.individuals i on i.id = a.individual_id;
  perform mirror.audit(p_individual, p_org, 'org_admin', 'view', 'audit', 'audit_logs', null);
  return jsonb_build_object('rows', v_rows, 'more', jsonb_array_length(v_rows) = 100);
end $function$
;

-- mirror_whoami: live body; NEW: change_notice

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
  v_state text;
  v_notice jsonb;
begin
  if v_email is null then return jsonb_build_object('signed_in', false); end if;
  -- a device past its Mirror limits (or signed out everywhere) counts as signed out: the page asks for a new code.
  -- A coordinator's screen lock is not signed out: the page asks for the authenticator code only.
  v_state := mirror.session_state();
  if v_state <> 'ok' and v_state <> 'locked' then return jsonb_build_object('signed_in', false, 'expired', true); end if;
  select jsonb_build_object('id', i.id, 'preferred_name', i.preferred_name) into v_person
    from mirror.individuals i where i.auth_email = v_email;
  select jsonb_agg(jsonb_build_object('organization_id', o.id, 'organization', o.name, 'role', m.role, 'name', m.name) order by o.name) into v_member
    from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active
    where m.auth_email = v_email and m.active;
  if v_person is not null then
    select count(*) into v_invites from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
     where oi.individual_id = (v_person ->> 'id')::uuid and oi.status = 'invited';
  end if;
  -- privacy page promise: a change in how information is used or shared is shown at sign-in before it starts, until read
  begin v_notice := nullif(trim(coalesce((select value from public.portal_settings where key = 'mirror_change_notice'), '')), '')::jsonb;
  exception when others then v_notice := null; end;
  if v_notice is not null and (v_notice ->> 'id') is not null
     and exists (select 1 from mirror.profiles pr where pr.auth_email = v_email and pr.notice_seen = v_notice ->> 'id') then v_notice := null; end if;
  return jsonb_build_object(
    'signed_in', true,
    'change_notice', v_notice,
    'locked', v_state = 'locked',
    'session', jsonb_build_object('device', mirror.session_device(), 'limits', mirror.session_limits()),
    'email', v_email,
    'aal', v_aal,
    'view_as', public.autopay_view_as_session(),
    'person', v_person,
    'memberships', coalesce(v_member, '[]'::jsonb),
    'needs_authenticator', v_member is not null and v_aal <> 'aal2',
    'invitations', v_invites,
    'signin_enabled', coalesce((select value from public.portal_settings where key = 'mirror_signin_enabled'), 'off') = 'on');
end $function$
;

-- mirror_my_deletion: live body; NEW: returns hidden_at

CREATE OR REPLACE FUNCTION public.mirror_my_deletion(p_request boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid := mirror.me();
begin
  update mirror.individuals set deletion_requested_at = case when p_request then coalesce(deletion_requested_at, now()) end where id = v;
  perform mirror.audit(v, null, 'self', case when p_request then 'delete_request' else 'delete_cancel' end, 'general', 'individuals', null);
  return (select jsonb_build_object('deletion_requested_at', deletion_requested_at, 'hidden_at', hidden_at, 'deletion_on', (deletion_requested_at + interval '30 days')::date)
          from mirror.individuals where id = v);
end $function$
;

-- mirror_person_status: live body; NEW: a hidden person cannot be restarted or invited again

CREATE OR REPLACE FUNCTION public.mirror_person_status(p_org uuid, p_individual uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare v_email text;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if p_status not in ('ended', 'active', 'invited') then raise exception 'Unknown status.' using errcode = '22023'; end if;
  select auth_email into v_email from mirror.individuals where id = p_individual;
  if p_status <> 'ended' and exists (select 1 from mirror.individuals where id = p_individual and hidden_at is not null) then
    raise exception 'This person cannot be restarted right now.' using errcode = '42501';
  end if;
  if p_status = 'active' and v_email is not null then
    raise exception 'This person has their own sign-in, so they say yes themselves on My Mirror. Invite them instead.' using errcode = '42501';
  end if;
  if p_status = 'invited' and v_email is null then
    raise exception 'This person has no email, so there is no invitation to send. Restart them instead.' using errcode = '22023';
  end if;
  update mirror.organization_individuals
     set status = p_status, ended_on = case when p_status = 'ended' then current_date else null end
   where organization_id = p_org and individual_id = p_individual;
  if not found then raise exception 'This person is not on your list.' using errcode = 'P0002'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'edit', 'general', 'organization_individuals', p_status);
end $function$
;

-- mirror_person_add: live body; NEW: a hidden person's email cannot be added

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
  perform mirror.rate_require('person_add');
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
  if v_id is not null and exists (select 1 from mirror.individuals where id = v_id and hidden_at is not null) then
    raise exception 'That email cannot be added. Call 2nd Chance at (262) 236-5443.' using errcode = '42501';
  end if;
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
;

revoke all on function mirror.adults_only(), mirror.hide_individual(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function mirror.hide_individual(uuid, uuid, text, text) to service_role;
revoke all on function public.mirror_my_hide(), public.mirror_my_unhide(), public.mirror_person_hide(uuid, uuid, text, boolean),
  public.mirror_platform_hide(text, boolean, text, boolean), public.mirror_notice_seen(text), public.mirror_admin_change_notice_set(text, date) from public, anon;
grant execute on function public.mirror_my_hide(), public.mirror_my_unhide(), public.mirror_person_hide(uuid, uuid, text, boolean),
  public.mirror_platform_hide(text, boolean, text, boolean), public.mirror_notice_seen(text), public.mirror_admin_change_notice_set(text, date)
  to authenticated, service_role;
