-- Mirror T6.4 check: the progress page (counts per area of life, history by month; D-09 no score). Fictional people and
-- fictional sign-ins; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t64-progress-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; h jsonb; g1 uuid; st1 uuid; nd1 uuid; nd2 uuid; n int; ok boolean;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid();
  pa text; pb text; cx text; c1 text; mo text := to_char(current_date, 'YYYY-MM');
begin
  insert into auth.users (id, email) values (ua, 'check.pa@example.invalid'), (ub, 'check.pb@example.invalid'), (uc, 'check.pcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now()), (sc1, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.pa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.pb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.pcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.pcx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.pa@example.invalid', 'CHECK PA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.pb@example.invalid', 'CHECK PB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.pcx@example.invalid', 'CHECK PCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the person: an open housing need, a private health need got, a work goal reached with a step done, a milestone with no area,
  --    a work strength; counts land in the right area, 15 areas, 12 months, no score anywhere
  perform set_config('request.jwt.claims', pa, true);
  nd1 := (public.mirror_need_save(null, 'housing', 'A place of my own', null, 'soon') ->> 'id')::uuid;
  nd2 := (public.mirror_need_save(null, 'physical_health', 'Glasses', null, 'soon') ->> 'id')::uuid;
  perform public.mirror_need_status(nd2, 'obtained', null);
  g1 := (public.mirror_goal_save(null, '{"dimension":"work","title":"Get a CDL","stage":"4"}') ->> 'id')::uuid;
  st1 := (public.mirror_action_save(null, jsonb_build_object('title', 'Get the handbook', 'goal_id', g1, 'status', 'done')) ->> 'id')::uuid;
  perform public.mirror_action_save(null, '{"title":"Call my sister"}');
  perform public.mirror_goal_save(g1, '{"dimension":"work","title":"Get a CDL","stage":"4","status":"achieved"}');
  perform public.mirror_milestone_save(null, '{"title":"Kept every appointment this month"}');
  perform public.mirror_strength_save(null, 'skill', 'Driving', null, 'work');
  j := public.mirror_progress();
  h := (select e from jsonb_array_elements(j -> 'history') e where e ->> 'month' = mo);
  ok := (j ->> 'self')::boolean and jsonb_array_length(j -> 'areas') = 15 and jsonb_array_length(j -> 'history') = 12
    and (select (e ->> 'needs_open')::int from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'housing') = 1
    and (select (e ->> 'needs_met')::int from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'physical_health') = 1
    and (select (e ->> 'goals_reached')::int + (e ->> 'steps_done')::int + (e ->> 'milestones')::int + (e ->> 'strengths')::int
           from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'work') = 4
    and (j -> 'no_area' ->> 'milestones')::int = 1 and (j -> 'no_area' ->> 'steps_open')::int = 1
    and (h ->> 'needs_noted')::int = 2 and (h ->> 'needs_met')::int = 1 and (h ->> 'goals_reached')::int = 1
    and (h ->> 'steps_done')::int = 1 and (h ->> 'milestones')::int = 2
    and j::text !~* '(score|percent|readiness|rank)';
  r := r || format('1 person: counts in the right areas (housing 1 open, health 1 got, work 4), no-area 1 milestone + 1 step, 15 areas, 12 months, this month 2/1/1/1/2, no score words: %s', ok);

  -- 2. coordinator, everyday topics only: private areas are "not shared" with NO counts; history leaves the private need out
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_progress(a);
  h := (select e from jsonb_array_elements(j -> 'history') e where e ->> 'month' = mo);
  ok := not (j ->> 'self')::boolean
    and (select count(*) from jsonb_array_elements(j -> 'areas') e where not (e ->> 'shared')::boolean) = 5
    and (select not (e ? 'needs_met') from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'physical_health')
    and (select (e ->> 'needs_open')::int from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'housing') = 1
    and (h ->> 'needs_noted')::int = 1 and (h ->> 'needs_met')::int = 0 and not (j ? 'hidden');
  r := r || format('2 coordinator (everyday only): 5 private areas "not shared" without counts, housing 1, history leaves the private need out, no hidden count: %s', ok);

  -- 3. the person shares health with "see and change"; the coordinator confirms the glasses; counts and history follow
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'health', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_need_status(nd2, 'verified', 'Saw the receipt');
  j := public.mirror_progress(a);
  h := (select e from jsonb_array_elements(j -> 'history') e where e ->> 'month' = mo);
  ok := (select (e ->> 'shared')::boolean and (e ->> 'needs_met')::int = 1 and (e ->> 'needs_verified')::int = 1
           from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'physical_health')
    and (h ->> 'needs_verified')::int = 1 and (h ->> 'needs_met')::int = 1
    and (select count(*) from jsonb_array_elements(j -> 'areas') e where not (e ->> 'shared')::boolean) = 4;
  r := r || format('3 health shared: the coordinator sees health (1 got, 1 confirmed), history 1 confirmed, 4 areas still not shared: %s', ok);

  -- 4. a reopened step no longer counts as done; no authenticator refused; person B sees only their own (empty) progress
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_progress(a); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pb, true);
  begin perform public.mirror_progress(a); ok := ok and false; exception when insufficient_privilege then null; end;
  j := public.mirror_progress();
  ok := ok and (select coalesce(sum((e ->> 'needs_open')::int + (e ->> 'needs_met')::int + (e ->> 'steps_done')::int + (e ->> 'milestones')::int), 0)
                from jsonb_array_elements(j -> 'areas') e) = 0;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_action_save(st1, jsonb_build_object('title', 'Get the handbook', 'goal_id', g1, 'status', 'open'));
  j := public.mirror_progress();
  ok := ok and (select (e ->> 'steps_done')::int from jsonb_array_elements(j -> 'areas') e where e ->> 'key' = 'work') = 0;
  r := r || format('4 no authenticator refused; B cannot see A and has 0 of everything; a reopened step is no longer done: %s', ok);

  -- 5. closed to browsers without sign-in; audit rows for the looks
  execute 'reset role';
  ok := not has_function_privilege('anon', 'public.mirror_progress(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.mirror_progress(uuid)', 'execute')
    and (select p.prosecdef and p.proconfig is not null from pg_proc p where p.oid = 'public.mirror_progress(uuid)'::regprocedure);
  select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'progress';
  r := r || format('5 not for anonymous, security definer with a fixed search_path, %s progress look rows: %s', n, ok and n > 0);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
