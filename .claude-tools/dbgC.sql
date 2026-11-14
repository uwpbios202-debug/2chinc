-- Phase 2 finding C check (migration 20261119269500): the Mirror's own sign-out limits and the coordinator screen lock.
-- Fictional people and fictional auth rows only; always rolled back: sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; ok boolean; st text;
  cu uuid := gen_random_uuid(); pu uuid := gen_random_uuid();
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); c3 uuid := gen_random_uuid();
  p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); p3 uuid := gen_random_uuid(); p4 uuid := gen_random_uuid();
  cj text; pj text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into auth.users (id, email) values (cu, 'check.sl.coord@example.invalid'), (pu, 'check.sl.person@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (c1, cu, now() - interval '2 days', now(), now()),                 -- coordinator, recent
    (c2, cu, now() - interval '8 days', now(), now()),                 -- coordinator, past 7 days
    (c3, cu, now() - interval '3 days', now() - interval '25 hours', now() - interval '25 hours'),   -- coordinator, unused 25 hours
    (p1, pu, now() - interval '60 days', now(), now()),                -- person, own device
    (p2, pu, now() - interval '5 minutes', now(), now()),              -- person, shared device
    (p3, pu, now() - interval '40 minutes', now(), now()),             -- person, never answered, 40 minutes ago
    (p4, pu, now() - interval '91 days', now(), now());                -- person, own device past 90 days
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method) values
    (gen_random_uuid(), c1, now() - interval '5 minutes', now() - interval '5 minutes', 'totp');
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.sl.coord@example.invalid', 'CHECK SL Coord', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.sl.person@example.invalid', 'CHECK SL Person', x) returning id into a;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (x, a, 'active', current_date);
  perform set_config('role', 'authenticated', true);

  -- 1 coordinator, authenticator 5 minutes ago: works, not locked; touch records activity
  cj := json_build_object('sub', cu, 'email', 'check.sl.coord@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', c1)::text;
  perform set_config('request.jwt.claims', cj, true);
  j := public.mirror_whoami();
  ok := (j ->> 'signed_in')::boolean and not (j ->> 'locked')::boolean and (j #>> '{session,limits,member_lock_minutes}')::int = 15;
  ok := ok and jsonb_array_length(public.mirror_people(x)) >= 1 and public.mirror_session_touch() ->> 'state' = 'ok';
  r := r || format('1 coordinator in use: works, not locked, limits sent to the page: %s', ok);

  -- 2 coordinator 16 minutes without activity: locked; data refused with the lock message; touching does not unlock
  execute 'reset role';
  update mirror.device_sessions set last_seen = now() - interval '16 minutes' where session_id = c1;
  update auth.mfa_amr_claims set updated_at = now() - interval '20 minutes' where session_id = c1;
  perform set_config('role', 'authenticated', true);
  j := public.mirror_whoami();
  ok := (j ->> 'signed_in')::boolean and (j ->> 'locked')::boolean;
  begin perform public.mirror_people(x); ok := false; exception when insufficient_privilege then ok := ok and sqlerrm like '%locked%'; end;
  ok := ok and public.mirror_session_touch() ->> 'state' = 'locked' and (public.mirror_whoami() ->> 'locked')::boolean;
  r := r || format('2 coordinator idle 16 minutes: screen locked, people list refused ("locked"), touch does not unlock: %s', ok);

  -- 3 the authenticator code again unlocks it
  execute 'reset role';
  update auth.mfa_amr_claims set updated_at = now() where session_id = c1;
  perform set_config('role', 'authenticated', true);
  ok := not (public.mirror_whoami() ->> 'locked')::boolean and jsonb_array_length(public.mirror_people(x)) >= 1;
  r := r || format('3 authenticator code entered again: unlocked, works: %s', ok);

  -- 4 coordinator past 7 days, or unused 25 hours: signed out (new email code needed)
  perform set_config('request.jwt.claims', json_build_object('sub', cu, 'email', 'check.sl.coord@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', c2)::text, true);
  ok := (public.mirror_whoami() ->> 'expired')::boolean;
  begin perform public.mirror_people(x); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', cu, 'email', 'check.sl.coord@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', c3)::text, true);
  ok := ok and (public.mirror_whoami() ->> 'expired')::boolean;
  r := r || format('4 coordinator 8 days after sign-in, or unused 25 hours: signed out: %s', ok);

  -- 5 person on their own device, signed in 60 days ago: works; after 31 days unused, or 91 days after sign-in: signed out
  execute 'reset role';   -- answered "my own" when signing in, 60 days ago; used today
  insert into mirror.device_sessions (session_id, user_id, shared, chosen_at, last_seen) values (p1, pu, false, now() - interval '60 days', now());
  perform set_config('role', 'authenticated', true);
  pj := json_build_object('sub', pu, 'email', 'check.sl.person@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', p1)::text;
  perform set_config('request.jwt.claims', pj, true);
  j := public.mirror_session_touch();
  ok := j ->> 'device' = 'own' and (public.mirror_my_settings() -> 'person' ->> 'preferred_name') = 'CHECK SL Person';
  execute 'reset role';
  update mirror.device_sessions set last_seen = now() - interval '31 days' where session_id = p1;
  update auth.sessions set refreshed_at = (now() - interval '31 days') at time zone 'utc', updated_at = now() - interval '31 days' where id = p1;
  perform set_config('role', 'authenticated', true);
  ok := ok and (public.mirror_whoami() ->> 'expired')::boolean;
  execute 'reset role';
  insert into mirror.device_sessions (session_id, user_id, shared, chosen_at, last_seen) values (p4, pu, false, now(), now());
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', pu, 'email', 'check.sl.person@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', p4)::text, true);
  begin perform public.mirror_my_settings(); ok := false; exception when insufficient_privilege then ok := ok and sqlerrm like '%expired%'; end;
  r := r || format('5 own device: works at 60 days; signed out after 31 days unused or 91 days after sign-in: %s', ok);

  -- 6 person on a shared device: works while in use; 31 minutes without activity: signed out; cannot switch to "own device"
  perform set_config('request.jwt.claims', json_build_object('sub', pu, 'email', 'check.sl.person@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', p2)::text, true);
  j := public.mirror_device_choose(true); r := r || format('6dbg choose=%s who=%s', j::text, public.mirror_whoami()::text); ok := true;
  begin perform public.mirror_device_choose(false); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('6dbg sets=%s', public.mirror_sets('reflection', null)::text);
  execute 'reset role';
  update mirror.device_sessions set last_seen = now() - interval '31 minutes' where session_id = p2;
  perform set_config('role', 'authenticated', true);
  ok := ok and (public.mirror_whoami() ->> 'expired')::boolean and public.mirror_session_touch() ->> 'state' = 'expired';
  begin perform public.mirror_sets('reflection', null); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('6 shared device: works in use, cannot become "own", signed out after 31 minutes idle (touch does not revive): %s', ok);

  -- 7 never answered the question: treated as shared (40 minutes after sign-in: signed out)
  perform set_config('request.jwt.claims', json_build_object('sub', pu, 'email', 'check.sl.person@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', p3)::text, true);
  ok := (public.mirror_whoami() ->> 'expired')::boolean;
  r := r || format('7 never answered "own or shared", 40 minutes after sign-in: signed out like a shared device: %s', ok);

  -- 8 signed out everywhere (the session no longer exists): signed out
  perform set_config('request.jwt.claims', json_build_object('sub', pu, 'email', 'check.sl.person@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  ok := (public.mirror_whoami() ->> 'expired')::boolean;
  execute 'reset role';
  r := r || format('8 signed out everywhere: signed out: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
