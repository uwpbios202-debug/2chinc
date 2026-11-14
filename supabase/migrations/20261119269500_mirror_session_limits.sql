-- The Human Mirror, Phase 2 finding C (Stephen, 11/13/2026): the Mirror's own sign-out limits, fitted to the people who use it.
--
-- Until now the Mirror used the site-wide limits (public.session_fresh(): Mirror people and coordinators 45 days idle / 180 days maximum).
-- That suits a person on their own phone, not a person on a library, shelter or borrowed device, and not a coordinator whose open laptop
-- shows many people's private answers. From now on, on top of session_fresh() (unchanged, shared with the rest of the site, D-22):
--
--   Coordinators and admins (an active member of an active organization):
--     signed out after 24 hours without use or 7 days after signing in (whichever first; then a new email code and authenticator code);
--     the screen LOCKS after 15 minutes without activity: their data is refused until they enter their authenticator code again
--     (auth.mfa_amr_claims 'totp' newer than the lock). Touching the session while locked never unlocks it.
--   A person on their OWN device: 30 days without use or 90 days after signing in.
--   A person on a SHARED device (or who has not answered "Is this your own phone or computer?" yet): 30 minutes without activity.
--     The page also forgets the sign-in when the browser closes (session cookie, client side), and "remember my email" is off.
--     A shared sign-in cannot be switched to "own device" later: sign in again on your own device.
--   Signed out everywhere (auth.sessions row gone): signed out, as before.
--
-- Activity is recorded by public.mirror_session_touch() (pages call it on load and at most every few minutes while someone is using
-- the page), in mirror.device_sessions, one row per sign-in session. Background token refreshes do not count as activity for the
-- 30-minute and 15-minute limits. Tokens without a session id (service calls; View-as is refused separately) keep the old rule.
-- Numbers can be changed without code in portal_settings (none are set today; the defaults below apply):
--   mirror_session_member_idle_hours 24, mirror_session_member_max_days 7, mirror_session_member_lock_minutes 15,
--   mirror_session_person_idle_days 30, mirror_session_person_max_days 90, mirror_session_shared_idle_minutes 30,
--   mirror_session_warn_seconds 120 (the warning before a short limit, with "Keep me signed in").
-- New table: no grants to anon or authenticated (the Mirror's rule); service_role all.

create table mirror.device_sessions (
  session_id uuid primary key,          -- auth.sessions.id (from the sign-in token)
  user_id    uuid not null,
  shared     boolean,                   -- null until answered; true = shared or public device
  chosen_at  timestamptz,
  last_seen  timestamptz not null default now()
);
create index device_sessions_last_seen on mirror.device_sessions (last_seen);
alter table mirror.device_sessions enable row level security;
revoke all on mirror.device_sessions from public, anon, authenticated;
grant all on mirror.device_sessions to service_role;

-- the limits, with portal_settings overrides
create or replace function mirror.session_limits()
returns jsonb language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object(
    'member_idle_hours',    coalesce(nullif(public.condo_setting('mirror_session_member_idle_hours', ''), '')::numeric, 24),
    'member_max_days',      coalesce(nullif(public.condo_setting('mirror_session_member_max_days', ''), '')::numeric, 7),
    'member_lock_minutes',  coalesce(nullif(public.condo_setting('mirror_session_member_lock_minutes', ''), '')::numeric, 15),
    'person_idle_days',     coalesce(nullif(public.condo_setting('mirror_session_person_idle_days', ''), '')::numeric, 30),
    'person_max_days',      coalesce(nullif(public.condo_setting('mirror_session_person_max_days', ''), '')::numeric, 90),
    'shared_idle_minutes',  coalesce(nullif(public.condo_setting('mirror_session_shared_idle_minutes', ''), '')::numeric, 30),
    'warn_seconds',         coalesce(nullif(public.condo_setting('mirror_session_warn_seconds', ''), '')::numeric, 120));
$$;

-- this sign-in's session id, or null (service calls)
create or replace function mirror.session_id()
returns uuid language plpgsql stable security definer set search_path = mirror, public as $$
begin
  return (auth.jwt() ->> 'session_id')::uuid;
exception when others then return null;
end $$;

-- 'own', 'shared', or null (not answered yet)
create or replace function mirror.session_device()
returns text language sql stable security definer set search_path = mirror, public as $$
  select case d.shared when true then 'shared' when false then 'own' end
  from mirror.device_sessions d where d.session_id = mirror.session_id();
$$;

-- 'ok', 'locked' (coordinator screen lock), 'expired' (sign in again), 'signed_out'
create or replace function mirror.session_state()
returns text language plpgsql stable security definer set search_path = mirror, public as $$
declare
  v_sid uuid := mirror.session_id();
  v_created timestamptz; v_seen timestamptz; v_totp timestamptz;
  d mirror.device_sessions;
  L jsonb;
begin
  if auth.uid() is null or auth.email() is null then return 'signed_out'; end if;
  if not coalesce(public.session_fresh(), false) then return 'expired'; end if;   -- the site-wide rule still applies first
  if v_sid is null then return 'ok'; end if;                                     -- no session id: nothing more to measure
  select s.created_at, coalesce(s.refreshed_at at time zone 'utc', s.updated_at, s.created_at) into v_created, v_seen
    from auth.sessions s where s.id = v_sid;
  if not found then return 'expired'; end if;                                    -- signed out everywhere
  select * into d from mirror.device_sessions where session_id = v_sid;
  L := mirror.session_limits();

  if exists (select 1 from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active
             where m.auth_email = lower(auth.email()) and m.active) then
    if now() - v_created > make_interval(days => (L ->> 'member_max_days')::int) then return 'expired'; end if;
    if now() - greatest(v_seen, d.last_seen) > make_interval(hours => (L ->> 'member_idle_hours')::int) then return 'expired'; end if;
    if coalesce(auth.jwt() ->> 'aal', '') = 'aal2' then
      select max(c.updated_at) into v_totp from auth.mfa_amr_claims c where c.session_id = v_sid and c.authentication_method = 'totp';
      if now() - coalesce(greatest(d.last_seen, v_totp), v_created) > make_interval(mins => (L ->> 'member_lock_minutes')::int) then
        return 'locked';
      end if;
    end if;
    return 'ok';
  end if;

  if d.shared is distinct from false then                                         -- shared, or not answered yet
    if now() - coalesce(d.last_seen, v_created) > make_interval(mins => (L ->> 'shared_idle_minutes')::int) then return 'expired'; end if;
  else                                                                            -- the person's own device
    if now() - v_created > make_interval(days => (L ->> 'person_max_days')::int) then return 'expired'; end if;
    if now() - greatest(v_seen, d.last_seen) > make_interval(days => (L ->> 'person_idle_days')::int) then return 'expired'; end if;
  end if;
  return 'ok';
end $$;

create or replace function mirror.session_ok()
returns boolean language sql stable security definer set search_path = mirror, public as $$
  select mirror.session_state() = 'ok';
$$;

create or replace function mirror.session_message()
returns text language sql stable security definer set search_path = mirror, public as $$
  select case mirror.session_state()
    when 'locked' then 'Your screen is locked. Enter your authenticator code to continue.'
    when 'signed_out' then 'Please sign in.'
    else 'Your sign-in on this device has expired. Please sign in again.' end;
$$;

revoke all on function mirror.session_limits(), mirror.session_id(), mirror.session_device(), mirror.session_state(), mirror.session_ok(),
  mirror.session_message() from public, anon, authenticated;
grant execute on function mirror.session_limits(), mirror.session_id(), mirror.session_device(), mirror.session_state(), mirror.session_ok(),
  mirror.session_message() to service_role;

-- ---------------------------------------------------------------- the gates (LIVE bodies of 11/13/2026; only the session lines changed)

CREATE OR REPLACE FUNCTION mirror.me()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid;
begin
  if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
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
    and mirror.session_ok();
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
  if not mirror.session_ok() then
    return jsonb_build_object('ok', false, 'reason', mirror.session_message());
  end if;
  if public.autopay_view_as_session() then
    if not v_probe then perform mirror.audit_refused(p_individual, p_org, 'view_as', p_category, p_table, p_row, 'view_as'); end if;
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
      if not v_probe then perform mirror.audit_refused(p_individual, m.organization_id, m.role, p_category, p_table, p_row, 'no_authenticator'); end if;
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
      if not v_probe then perform mirror.audit_refused(p_individual, v_org, v_role, p_category, p_table, p_row, 'no_consent'); end if;
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
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
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
  v_state text;
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
  return jsonb_build_object(
    'signed_in', true,
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
end $function$;

-- ---------------------------------------------------------------- what the pages call

-- "I'm still here": records activity for this sign-in. Never unlocks a locked screen and never revives an expired sign-in.
create or replace function public.mirror_session_touch()
returns jsonb language plpgsql volatile security definer set search_path = mirror, public as $$
declare v_sid uuid := mirror.session_id(); v_state text := mirror.session_state();
begin
  if v_state = 'ok' and v_sid is not null then
    insert into mirror.device_sessions (session_id, user_id, last_seen) values (v_sid, auth.uid(), now())
      on conflict (session_id) do update set last_seen = now();
    delete from mirror.device_sessions where last_seen < now() - interval '120 days';   -- old sign-ins: nothing left to measure
  end if;
  return jsonb_build_object('state', v_state, 'device', mirror.session_device());
end $$;

-- "Is this your own phone or computer?" Once shared, always shared for this sign-in.
create or replace function public.mirror_device_choose(p_shared boolean)
returns jsonb language plpgsql volatile security definer set search_path = mirror, public as $$
declare v_sid uuid := mirror.session_id(); v_prev boolean;
begin
  if auth.email() is null or v_sid is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
  if p_shared is null then raise exception 'Choose "my own" or "shared".' using errcode = '22023'; end if;
  select shared into v_prev from mirror.device_sessions where session_id = v_sid;
  if v_prev is true and not p_shared then
    raise exception 'This sign-in started on a shared device. To stay signed in longer, sign out and sign in again on your own phone or computer.' using errcode = '42501';
  end if;
  insert into mirror.device_sessions (session_id, user_id, shared, chosen_at, last_seen) values (v_sid, auth.uid(), p_shared, now(), now())
    on conflict (session_id) do update set shared = excluded.shared, chosen_at = now(), last_seen = now();
  return jsonb_build_object('state', mirror.session_state(), 'device', mirror.session_device());
end $$;

revoke all on function public.mirror_session_touch(), public.mirror_device_choose(boolean) from public, anon;
grant execute on function public.mirror_session_touch(), public.mirror_device_choose(boolean) to authenticated, service_role;
