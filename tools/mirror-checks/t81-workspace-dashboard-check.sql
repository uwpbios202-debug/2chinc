-- Mirror T8.1 + P2-07 check: workspace dashboard, people counts, the organization's own audit log. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t81-workspace-dashboard-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; c uuid; j jsonb; n int; ok boolean; nh uuid; t text; k bigint;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uad uuid := gen_random_uuid(); uv uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid(); sad uuid := gen_random_uuid(); sv uuid := gen_random_uuid();
  pa text; cx text; c1 text; ad text; vx text;
begin
  insert into auth.users (id, email) values (ua, 'check.wa@example.invalid'), (uc, 'check.wcx@example.invalid'),
    (uad, 'check.wad@example.invalid'), (uv, 'check.wvx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now()),
    (sc1, uc, now(), now(), now()), (sad, uad, now(), now(), now()), (sv, uv, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.wa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.wcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.wcx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  ad := json_build_object('sub', uad, 'email', 'check.wad@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sad)::text;
  vx := json_build_object('sub', uv, 'email', 'check.wvx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sv)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.wa@example.invalid', 'CHECK WA', x) returning id into a;
  insert into mirror.individuals (preferred_name) values ('CHECK WB') returning id into b;            -- active, but not known to the organization
  insert into mirror.individuals (preferred_name) values ('CHECK WC') returning id into c;            -- invited only
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.wcx@example.invalid', 'CHECK Coordinator', 'coordinator'), (x, 'check.wad@example.invalid', 'CHECK Admin', 'org_admin'),
    (x, 'check.wvx@example.invalid', 'CHECK Volunteer', 'volunteer');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active'), (x, b, 'active'), (x, c, 'invited');
  insert into mirror.needs (individual_id, dimension_key, category, title, urgency, identified_by, identified_by_role)
    values (b, 'housing', 'general', 'B secret need', 'urgent', 'x', 'self');
  perform mirror.audit(b, x, 'coordinator', 'view', 'health', 'needs', null, null);
  perform set_config('role', 'authenticated', true);

  -- A: an urgent everyday need and an urgent private (health) need; steps due soon (everyday + private) and one far off; two help answers
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_need_save(null, 'housing', 'Somewhere to sleep tonight', null, 'urgent');
  nh := (public.mirror_need_save(null, 'physical_health', 'Insulin', null, 'urgent') ->> 'id')::uuid;
  perform public.mirror_action_save(null, jsonb_build_object('title', 'Call the shelter line', 'due_on', (current_date + 2)::text));
  perform public.mirror_action_save(null, jsonb_build_object('title', 'Go to the clinic', 'need_id', nh, 'due_on', current_date::text));
  perform public.mirror_action_save(null, jsonb_build_object('title', 'Look at apartments', 'due_on', (current_date + 30)::text));
  perform public.mirror_answer_save('dimension_housing', 'have', null, 'needs_help', 'I need a bed');
  perform public.mirror_answer_save('dimension_physical_health', 'have', null, 'needs_help', 'Need a dentist');

  -- 1. coordinator: everyday items only, B (not known) and far-off step left out, counts of people; no hidden counts
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_workspace_dashboard(x);
  ok := jsonb_array_length(j -> 'urgent_needs') = 1 and j -> 'urgent_needs' -> 0 ->> 'title' = 'Somewhere to sleep tonight'
    and jsonb_array_length(j -> 'due_steps') = 1 and j -> 'due_steps' -> 0 ->> 'title' = 'Call the shelter line'
    and jsonb_array_length(j -> 'help') = 1 and j -> 'help' -> 0 ->> 'note' = 'I need a bed'
    and (j -> 'people' ->> 'active')::int >= 2 and (j -> 'people' ->> 'invited')::int >= 1
    and j::text !~ 'B secret need' and j::text !~ 'Insulin' and j::text !~ 'dentist' and not (j ? 'hidden');
  execute 'reset role'; select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'workspace_dashboard'; perform set_config('role', 'authenticated', true);
  ok := ok and n = 0;
  r := r || format('1 coordinator sees 1 urgent need, 1 step due, 1 help answer (everyday only); unknown person and far-off step left out; no private item, no hidden count, nothing logged: %s', ok);

  -- 2. A shares health (view): the private items appear and each private look is logged
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'health', 'view');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_workspace_dashboard(x);
  ok := jsonb_array_length(j -> 'urgent_needs') = 2 and jsonb_array_length(j -> 'due_steps') = 2 and jsonb_array_length(j -> 'help') = 2
    and (j -> 'due_steps' -> 0 ->> 'title') = 'Go to the clinic' and (j -> 'due_steps' -> 0 ->> 'private')::boolean;
  execute 'reset role'; select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'workspace_dashboard' and category = 'health'; perform set_config('role', 'authenticated', true);
  ok := ok and n = 1;
  r := r || format('2 health shared: 2 urgent needs, 2 steps (soonest first, marked private), 2 help answers; %s private look logged: %s', n, ok);

  -- 3. people counts: only A (known, active), visible topics only; looks logged
  j := public.mirror_people_counts(x);
  ok := (select count(*) from jsonb_array_elements(j) e where e ->> 'id' in (a::text, b::text, c::text)) = 1
    and (select (e ->> 'needs_open')::int = 2 and (e ->> 'needs_urgent')::int = 2 and (e ->> 'steps_open')::int = 3
           from jsonb_array_elements(j) e where e ->> 'id' = a::text);
  execute 'reset role'; select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'workspace_people'; perform set_config('role', 'authenticated', true);
  r := r || format('3 people counts: only the known active person; 2 open needs (2 urgent), 3 open steps; %s look logged: %s', n, ok and n = 1);

  -- 4. refused: no authenticator, a volunteer, the person, and coordinators for the audit log
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_workspace_dashboard(x); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', vx, true);
  begin perform public.mirror_workspace_dashboard(x); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_people_counts(x); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  begin perform public.mirror_workspace_dashboard(x); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_org_audit(x); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 refused without the authenticator, for a volunteer, for the person, and the audit log for a coordinator: %s', ok);

  -- 5. P2-07: the organization admin reads the log: names, never emails; an unknown person is not named; reading is logged; paging; one person
  perform set_config('request.jwt.claims', ad, true);
  j := public.mirror_org_audit(x);
  t := j::text;
  ok := jsonb_array_length(j -> 'rows') > 0 and t !~ '@' and t ~ 'CHECK Coordinator' and t !~ 'CHECK WB' and t ~ 'A person not on your list';
  j := public.mirror_org_audit(x, null, a);
  ok := ok and jsonb_array_length(j -> 'rows') > 0 and not exists (select 1 from jsonb_array_elements(j -> 'rows') e where e ->> 'person_id' is distinct from a::text);
  k := (j -> 'rows' -> 0 ->> 'id')::bigint;
  j := public.mirror_org_audit(x, k);
  ok := ok and not exists (select 1 from jsonb_array_elements(j -> 'rows') e where (e ->> 'id')::bigint >= k) and jsonb_array_length(j -> 'rows') > 0;
  execute 'reset role'; select count(*) into n from mirror.audit_logs where organization_id = x and category = 'audit' and table_name = 'audit_logs' and actor_email = 'check.wad@example.invalid'; perform set_config('role', 'authenticated', true);
  r := r || format('5 org admin reads the log: names not emails, unknown person unnamed, one-person filter, older page; %s reads logged: %s', n, ok and n = 3);

  -- 6. closed: not for anonymous; helpers not callable by signed-in users; security definer with a fixed search_path
  execute 'reset role';
  ok := not has_function_privilege('anon', 'public.mirror_workspace_dashboard(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_org_audit(uuid, bigint, uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_people_counts(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.org_sees(uuid, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.log_private_looks(uuid, uuid, text[], text)', 'execute')
    and (select bool_and(p.prosecdef and p.proconfig is not null) from pg_proc p where p.oid in
         ('public.mirror_workspace_dashboard(uuid)'::regprocedure, 'public.mirror_people_counts(uuid)'::regprocedure, 'public.mirror_org_audit(uuid, bigint, uuid)'::regprocedure));
  r := r || format('6 closed to anonymous, helpers closed, security definer with fixed search_path: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
