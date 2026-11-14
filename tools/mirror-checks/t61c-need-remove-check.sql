-- Mirror T6.1 follow-up check: the person removes their own need (with its history and steps); nobody else can; direct deletes stay blocked.
-- Fictional people and fictional sign-ins; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; h uuid; p uuid; n int; ok boolean;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; pb text; cx text;
begin
  insert into auth.users (id, email) values (ua, 'check.ra@example.invalid'), (ub, 'check.rb@example.invalid'), (uc, 'check.rcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ra@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.rb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.rcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ra@example.invalid', 'CHECK RA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.rb@example.invalid', 'CHECK RB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.rcx@example.invalid', 'CHECK RCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- person A: two needs, one with history and a step
  perform set_config('request.jwt.claims', pa, true);
  h := (public.mirror_need_save(null, 'housing', 'A place of my own', null, 'urgent') ->> 'id')::uuid;
  p := (public.mirror_need_save(null, 'physical_health', 'Something I regret writing', null, 'soon') ->> 'id')::uuid;
  perform public.mirror_need_status(p, 'planning', 'note');
  perform public.mirror_action_save(null, jsonb_build_object('title', 'Call', 'need_id', p));
  perform public.mirror_my_consent_set(x, 'general', 'edit');

  -- 1. coordinator with edit sharing cannot remove; person B cannot remove A's need
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_need_delete(h); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pb, true);
  begin perform public.mirror_need_delete(h); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('1 coordinator (with see and change) and another person cannot remove a need: %s', ok);

  -- 2. the person removes one: gone with its history and step; the other need stays; the flag does not linger
  perform set_config('request.jwt.claims', pa, true);
  ok := public.mirror_need_delete(p);
  ok := ok and jsonb_array_length(public.mirror_needs_list() -> 'needs') = 1 and jsonb_array_length(public.mirror_plan() -> 'actions') = 0
    and coalesce(current_setting('mirror.need_remove', true), '') = '';
  execute 'reset role';
  ok := ok and not exists (select 1 from mirror.need_events where need_id = p) and exists (select 1 from mirror.needs where id = h);
  r := r || format('2 person removes own need: need, history and step gone; other need kept; flag cleared: %s', ok);

  -- 3. a direct delete is still blocked (even by the database owner), and a stale flag for another need does not open it
  begin delete from mirror.needs where id = h; ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('mirror.need_remove', gen_random_uuid()::text, true);
  begin delete from mirror.needs where id = h; ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('mirror.need_remove', '', true);
  -- deleting the whole Mirror still removes everything
  delete from mirror.individuals where id = a;
  select count(*) into n from mirror.needs where individual_id = a;
  ok := ok and n = 0 and not has_function_privilege('anon', 'public.mirror_need_delete(uuid)', 'execute');
  r := r || format('3 direct deletes still blocked (also with a flag for another need); whole Mirror delete still works; anon cannot call: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
