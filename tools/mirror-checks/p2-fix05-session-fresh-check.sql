-- Phase 2 fix 5 check (migration 20261119269000): an expired remembered device is signed out in the Mirror too.
-- Fictional people and fictional auth rows only; always rolled back: sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
-- Note for all Mirror checks from fix 5 on: fictional sign-ins carry NO session_id (session_fresh() then has nothing to measure), unless a
-- check creates its own auth.sessions row, as this one does.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; uid uuid := gen_random_uuid(); s_fresh uuid := gen_random_uuid(); s_old uuid := gen_random_uuid(); s_idle uuid := gen_random_uuid();
  j jsonb; ok boolean;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into auth.users (id, email) values (uid, 'check.sf@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (s_fresh, uid, now() - interval '1 day', now(), now()),
    (s_old,   uid, now() - interval '400 days', now(), now()),                                   -- past every maximum
    (s_idle,  uid, now() - interval '100 days', now() - interval '100 days', now() - interval '100 days');  -- past every idle limit
  -- since migration 20261119269500 (Mirror sign-out limits): the fresh session is one in use (authenticator code and page activity now)
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method) values (gen_random_uuid(), s_fresh, now(), now(), 'totp');
  insert into mirror.device_sessions (session_id, user_id, shared, chosen_at, last_seen) values (s_fresh, uid, false, now() - interval '1 day', now());
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.sf@example.invalid', 'CHECK SF Coord', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.sf.p@example.invalid', 'CHECK SF Person', x) returning id into a;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (x, a, 'active', current_date);
  perform set_config('role', 'authenticated', true);

  -- 1 a fresh session works as before (coordinator lists people; whoami signed in)
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'check.sf@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', s_fresh)::text, true);
  j := public.mirror_whoami();
  ok := (j ->> 'signed_in')::boolean and jsonb_array_length(public.mirror_people(x)) >= 1;
  r := r || format('1 fresh session: signed in, coordinator works: %s', ok);

  -- 2 a session past its maximum days: whoami says expired; coordinator functions refused; data gate refuses with the reason
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'check.sf@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', s_old)::text, true);
  j := public.mirror_whoami();
  ok := not (j ->> 'signed_in')::boolean and (j ->> 'expired')::boolean;
  begin perform public.mirror_people(x); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';   -- mirror.allowed is internal (no browser grant); same sign-in claims, called as the owner
  ok := ok and not (mirror.allowed(a, 'general', 'view') ->> 'ok')::boolean and mirror.allowed(a, 'general', 'view') ->> 'reason' like '%expired%';
  perform set_config('role', 'authenticated', true);
  r := r || format('2 past maximum days: whoami expired, coordinator refused, data gate says expired: %s', ok);

  -- 3 a session idle too long, and a session that no longer exists (signed out everywhere): same
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'check.sf@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', s_idle)::text, true);
  ok := (public.mirror_whoami() ->> 'expired')::boolean;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'check.sf@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  ok := ok and (public.mirror_whoami() ->> 'expired')::boolean;
  begin perform public.mirror_admin_orgs(); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('3 idle too long, and signed out everywhere: expired, admin refused: %s', ok);

  -- 4 the person themself on an expired device: my pages and "who looked" refused with the expired message
  execute 'reset role';
  update mirror.individuals set auth_email = 'check.sf@example.invalid' where id = a;
  delete from mirror.organization_members where auth_email = 'check.sf@example.invalid';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'check.sf@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s_old)::text, true);
  ok := true;
  begin perform public.mirror_my_settings(); ok := false; exception when insufficient_privilege then ok := sqlerrm like '%expired%'; end;
  begin perform public.mirror_who_looked(); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_sets('reflection', null); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('4 person on an expired device: settings, who looked and their sets refused ("expired"): %s', ok);

  -- 5 the same person on a fresh device works
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'check.sf@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s_fresh)::text, true);
  ok := (public.mirror_my_settings() -> 'person' ->> 'preferred_name') = 'CHECK SF Person' and jsonb_array_length(public.mirror_sets('reflection', null)) > 0;
  execute 'reset role';
  r := r || format('5 person on a fresh device: settings and sets work: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
