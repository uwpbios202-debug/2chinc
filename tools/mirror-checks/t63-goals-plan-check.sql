-- Mirror T6.3 check: goals by stage, steps, milestones. Fictional people and fictional sign-ins; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t63-goals-plan-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; g1 uuid; g2 uuid; s1 uuid; s2 uuid; m1 uuid; m2 uuid; nd uuid; n int; ok boolean;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid();
  pa text; pb text; cx text; c1 text;
begin
  insert into auth.users (id, email) values (ua, 'check.ga@example.invalid'), (ub, 'check.gb@example.invalid'), (uc, 'check.gcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now()), (sc1, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ga@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.gb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.gcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.gcx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ga@example.invalid', 'CHECK GA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.gb@example.invalid', 'CHECK GB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.gcx@example.invalid', 'CHECK GCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. person sets an everyday goal (stage 4, a hope-by date) and a private one (no stage); bad input refused in plain words
  perform set_config('request.jwt.claims', pa, true);
  g1 := (public.mirror_goal_save(null, '{"dimension":"work","title":"Get a CDL","stage":"4","hope_by":"2027-06-01"}') ->> 'id')::uuid;
  g2 := (public.mirror_goal_save(null, '{"dimension":"mental_health","title":"Find a counselor I trust"}') ->> 'id')::uuid;
  j := public.mirror_plan();
  ok := (j ->> 'self')::boolean and jsonb_array_length(j -> 'goals') = 2 and jsonb_array_length(j -> 'can_add') = 6
    and (select (e ->> 'stage')::int from jsonb_array_elements(j -> 'goals') e where e ->> 'title' = 'Get a CDL') = 4
    and (select (e ->> 'private')::boolean from jsonb_array_elements(j -> 'goals') e where e ->> 'title' = 'Find a counselor I trust');
  begin perform public.mirror_goal_save(null, '{"dimension":"work","title":" "}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_goal_save(null, '{"dimension":"nowhere","title":"x"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_goal_save(null, '{"dimension":"work","title":"x","stage":"7"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_goal_save(null, '{"dimension":"work","title":"x","hope_by":"2027-02-30"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_goal_save(null, '{"dimension":"work","title":"x","status":"late"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('1 person sets 2 goals (stage label, optional date, private one marked), may add in all 6 topics, bad input refused: %s', ok);

  -- 2. steps: one for the goal, one by a helper for a need; the need's private topic carries over; checks on input
  nd := (public.mirror_need_save(null, 'physical_health', 'Dentist', null, 'soon') ->> 'id')::uuid;
  s1 := (public.mirror_action_save(null, jsonb_build_object('title', 'Get the CDL handbook', 'goal_id', g1, 'due_on', '2026-12-01')) ->> 'id')::uuid;
  s2 := (public.mirror_action_save(null, jsonb_build_object('title', 'Call the dental clinic', 'need_id', nd, 'who', 'helper', 'helper', 'My sister')) ->> 'id')::uuid;
  j := public.mirror_plan();
  ok := jsonb_array_length(j -> 'actions') = 2 and jsonb_array_length(j -> 'needs') = 1
    and (select e ->> 'category' from jsonb_array_elements(j -> 'actions') e where e ->> 'id' = s2::text) = 'health'
    and (select e ->> 'helper' from jsonb_array_elements(j -> 'actions') e where e ->> 'id' = s2::text) = 'My sister';
  begin perform public.mirror_action_save(null, jsonb_build_object('title', 'x', 'goal_id', g1, 'need_id', nd)); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_action_save(null, '{"title":"x","who":"helper"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  j := public.mirror_action_save(s1, jsonb_build_object('title', 'Get the CDL handbook', 'goal_id', g1, 'status', 'done'));
  ok := ok and j ->> 'status' = 'done' and j ->> 'done_at' is not null;
  r := r || format('2 steps for a goal and (by a helper) for a private need, topic carried, one goal-or-need only, helper named, marked done: %s', ok);

  -- 3. reaching a goal adds one milestone (once); the person adds a milestone of their own; future dates refused
  perform public.mirror_goal_save(g1, '{"dimension":"work","title":"Get a CDL","stage":"4","status":"achieved"}');
  perform public.mirror_goal_save(g1, '{"dimension":"work","title":"Get a CDL","stage":"4","status":"achieved","detail":"Class B"}');
  m1 := (public.mirror_milestone_save(null, '{"title":"Six months sober","dimension":"physical_health"}') ->> 'id')::uuid;
  j := public.mirror_plan();
  ok := jsonb_array_length(j -> 'milestones') = 2
    and (select count(*) from jsonb_array_elements(j -> 'milestones') e where (e ->> 'automatic')::boolean and e ->> 'title' = 'Get a CDL') = 1;
  begin perform public.mirror_milestone_save(null, jsonb_build_object('title', 'x', 'achieved_on', (((now() at time zone 'America/Chicago')::date) + 3)::text)); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_milestone_confirm(m1); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role'; select id into m2 from mirror.milestones where goal_id = g1 and automatic; perform set_config('role', 'authenticated', true);
  r := r || format('3 reaching a goal adds 1 milestone (not twice); own milestone added; future date refused; person cannot confirm own: %s', ok);

  -- 4. coordinator (everyday view only): sees everyday goal, step and milestone only, NO hidden count, cannot add or change
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_plan(a);
  ok := not (j ->> 'self')::boolean and jsonb_array_length(j -> 'goals') = 1 and jsonb_array_length(j -> 'actions') = 1
    and jsonb_array_length(j -> 'milestones') = 1 and jsonb_array_length(j -> 'needs') = 0 and not (j ? 'hidden') and jsonb_array_length(j -> 'can_add') = 0;
  begin perform public.mirror_goal_save(null, '{"dimension":"work","title":"Forklift"}', a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_action_save(s1, jsonb_build_object('title', 'x', 'goal_id', g1)); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_action_save(null, jsonb_build_object('title', 'x', 'need_id', nd), a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator (view only) sees 1 goal, 1 step, 1 milestone, no private items and no hidden count, cannot add or change: %s', ok);

  -- 5. with "see and change": coordinator adds a goal (marked theirs), confirms the automatic milestone, cannot remove anything,
  --    cannot touch the private goal; no authenticator = refused; person B sees nothing of A
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_goal_save(null, '{"dimension":"housing","title":"Apply for the Riverwest list","stage":"3"}', a);
  ok := j ->> 'set_by_role' = 'coordinator';
  j := public.mirror_milestone_confirm(m2);
  ok := ok and (j ->> 'verified')::boolean;
  begin perform public.mirror_plan_delete('goal', g1); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_goal_save(g2, '{"dimension":"mental_health","title":"x"}'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_goal_save(g1, '{"dimension":"mental_health","title":"Get a CDL","status":"achieved"}'); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_plan(a); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pb, true);
  j := public.mirror_plan();
  ok := ok and jsonb_array_length(j -> 'goals') = 0 and jsonb_array_length(j -> 'milestones') = 0;
  begin perform public.mirror_plan(a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_plan_delete('action', s1); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_action_save(null, jsonb_build_object('title', 'sneak', 'goal_id', g1)); ok := ok and false; exception when no_data_found then null; end;
  r := r || format('5 with edit sharing: coordinator adds a goal and confirms a milestone, cannot remove or touch private; no authenticator refused; B sees nothing of A: %s', ok);

  -- 6. editing a confirmed milestone's words takes the confirmation off; removing a goal removes its steps and keeps its milestone;
  --    download; tables and helpers closed; audit rows
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_milestone_save(m2, jsonb_build_object('title', 'Got my CDL', 'goal_id', g1, 'achieved_on', ((now() at time zone 'America/Chicago')::date)::text));
  ok := not (j ->> 'verified')::boolean;
  ok := ok and public.mirror_plan_delete('goal', g1);
  j := public.mirror_plan();
  ok := ok and jsonb_array_length(j -> 'goals') = 2 and jsonb_array_length(j -> 'actions') = 1 and jsonb_array_length(j -> 'milestones') = 2;
  j := public.mirror_my_export_plan();
  ok := ok and jsonb_array_length(j -> 'goals') = 2 and jsonb_array_length(j -> 'steps') = 1 and jsonb_array_length(j -> 'milestones') = 2;
  execute 'reset role';
  ok := ok and not has_table_privilege('authenticated', 'mirror.goals', 'select') and not has_table_privilege('anon', 'mirror.milestones', 'select')
     and not has_table_privilege('authenticated', 'mirror.action_items', 'insert')
     and not has_function_privilege('anon', 'public.mirror_plan(uuid)', 'execute');
  begin truncate mirror.goals cascade; ok := ok and false; exception when insufficient_privilege then null; end;
  select count(*) into n from mirror.audit_logs where individual_id = a and table_name in ('goals', 'action_items', 'milestones');
  r := r || format('6 edited milestone loses confirmation; goal removed takes its step, keeps its milestone; download 2/1/2; closed to browsers; no truncate; %s audit rows: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
