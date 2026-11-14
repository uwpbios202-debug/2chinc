-- Mirror T6.3 part 2 check: goals suggested from the Vision reflection ("Who do I want to become?"), added by the person.
-- Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t63b-goal-suggestions-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; g jsonb; n int; ok boolean; long text := repeat('a home with a yard ', 20);
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; cx text;
begin
  insert into auth.users (id, email) values (ua, 'check.va@example.invalid'), (uc, 'check.vcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.va@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.vcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.va@example.invalid', 'CHECK VA') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.vcx@example.invalid', 'CHECK VCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. six Vision answers (one long, one money, one private health, one with no area, one skipped) -> five suggestions in the right areas
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_answer_save('reflection_vision', 'work', '"Drive a truck"');
  perform public.mirror_answer_save('reflection_vision', 'home', to_jsonb(long));
  perform public.mirror_answer_save('reflection_vision', 'income', '3200');
  perform public.mirror_answer_save('reflection_vision', 'health', '"Walk without pain"');
  perform public.mirror_answer_save('reflection_vision', 'own', '"A car"');
  perform public.mirror_answer_save('reflection_vision', 'learn', null, 'prefer_not');
  j := public.mirror_goal_suggestions();
  ok := jsonb_array_length(j) = 5
    and (select e ->> 'dimension' from jsonb_array_elements(j) e where e ->> 'key' = 'vision:work') = 'work'
    and (select e ->> 'dimension' from jsonb_array_elements(j) e where e ->> 'key' = 'vision:home') = 'housing'
    and (select length(e ->> 'title') = 200 and right(e ->> 'title', 1) = '…' and length(e ->> 'detail') = length(btrim(long))
         from jsonb_array_elements(j) e where e ->> 'key' = 'vision:home')
    and (select e ->> 'title' = 'Earn about $3,200 a month' and e ->> 'dimension' = 'finances' and (e ->> 'private')::boolean
         from jsonb_array_elements(j) e where e ->> 'key' = 'vision:income')
    and (select e ->> 'dimension' = 'physical_health' and (e ->> 'private')::boolean from jsonb_array_elements(j) e where e ->> 'key' = 'vision:health')
    and (select e ->> 'dimension' is null from jsonb_array_elements(j) e where e ->> 'key' = 'vision:own')
    and not exists (select 1 from jsonb_array_elements(j) e where e ->> 'key' = 'vision:learn');
  r := r || format('1 five suggestions from six answers (skipped one left out); work, housing (long answer cut to 200, whole answer kept), money -> "Earn about $3,200 a month" in finances (private), health private, "own" has no area: %s', ok);

  -- 2. adding: with the person's own words; with no area refused until one is picked; "Not now" hides one; added ones do not come back
  g := public.mirror_goal_add_suggested('vision:work', 'Get my CDL and drive a truck');
  ok := g ->> 'title' = 'Get my CDL and drive a truck' and g ->> 'dimension' = 'work' and g ->> 'set_by_role' = 'self' and g ->> 'status' = 'active' and g ->> 'stage' is null;
  begin perform public.mirror_goal_add_suggested('vision:own'); ok := ok and false; exception when invalid_parameter_value then null; end;
  g := public.mirror_goal_add_suggested('vision:own', null, 'transportation');
  ok := ok and g ->> 'title' = 'A car' and g ->> 'dimension' = 'transportation';
  g := public.mirror_goal_add_suggested('vision:income');
  ok := ok and g ->> 'category' = 'financial' and (g ->> 'private')::boolean;
  begin perform public.mirror_goal_add_suggested('vision:home', repeat('x', 201)); ok := ok and false; exception when invalid_parameter_value then null; end;
  perform public.mirror_goal_suggestion_dismiss('vision:health');
  j := public.mirror_goal_suggestions();
  ok := ok and jsonb_array_length(j) = 1 and j -> 0 ->> 'key' = 'vision:home';
  begin perform public.mirror_goal_add_suggested('vision:work'); ok := ok and false; exception when no_data_found then null; end;
  perform public.mirror_answer_save('reflection_vision', 'work', '"Run my own trucking business"');
  ok := ok and jsonb_array_length(public.mirror_goal_suggestions()) = 1;
  r := r || format('2 added in own words, area required when none, money goal private, 201 letters refused, "Not now" hides, added ones never come back (even after a new answer): %s', ok);

  -- 3. the coordinator gets no suggestions of the person (person only) and sees only everyday goals; download marks goals from answers
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_goal_suggestions(); ok := false; exception when others then ok := true; end;
  begin perform public.mirror_goal_add_suggested('vision:home'); ok := ok and false; exception when others then null; end;
  j := public.mirror_plan(a);
  ok := ok and jsonb_array_length(j -> 'goals') = 2;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_plan();
  ok := ok and (select count(*) from jsonb_array_elements(j -> 'goals') e where (e ->> 'from_your_answers')::boolean) = 3
    and jsonb_array_length(j -> 'goals_set_aside') = 1;
  r := r || format('3 a coordinator gets no suggestions and cannot add one; sees the 2 everyday goals only; download marks 3 goals from answers and 1 set aside: %s', ok);

  -- 4. closed: the new table has no browser grants, helpers not callable, functions not for anonymous
  execute 'reset role';
  ok := not has_table_privilege('authenticated', 'mirror.goal_suggestion_dismissals', 'select')
    and not has_table_privilege('anon', 'mirror.goal_suggestion_dismissals', 'select')
    and (select relrowsecurity from pg_class where oid = 'mirror.goal_suggestion_dismissals'::regclass)
    and not has_function_privilege('authenticated', 'mirror.goal_suggestions_for(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_goal_suggestions()', 'execute')
    and not has_function_privilege('anon', 'public.mirror_goal_add_suggested(text, text, text)', 'execute');
  r := r || format('4 dismissals table: row security on, no grants to browsers; helper closed; functions not for anonymous: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
