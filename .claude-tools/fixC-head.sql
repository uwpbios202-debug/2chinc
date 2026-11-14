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
