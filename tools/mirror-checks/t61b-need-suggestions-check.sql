-- Mirror T6.1 part 2 check: needs suggested from the person's answers, added with one tap. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; n int; ok boolean; k text;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; cx text;
begin
  insert into auth.users (id, email) values (ua, 'check.qa@example.invalid'), (uc, 'check.qcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.qa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.qcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.qa@example.invalid', 'CHECK QA') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.qcx@example.invalid', 'CHECK QCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. five kinds of answers -> five suggestions, one per key (housing named twice), private ones kept in their private area
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_answer_save('dimension_housing', 'help_wanted', '"now"');
  perform public.mirror_answer_save('reflection_needs', 'help_areas', '["housing","food"]');
  perform public.mirror_answer_save('dimension_physical_health', 'have', null, 'needs_help', 'Need a dentist');
  perform public.mirror_answer_save('reflection_identity', 'afraid', null, 'needs_help', 'Panic at night');
  perform public.mirror_answer_save('reflection_identity', 'have', null, 'needs_help');
  j := public.mirror_need_suggestions();
  ok := jsonb_array_length(j) = 5
    and (select e ->> 'dimension' from jsonb_array_elements(j) e where e ->> 'key' = 'q:dimension_physical_health:have') = 'physical_health'
    and (select (e ->> 'private')::boolean and e ->> 'title' = 'Need a dentist' from jsonb_array_elements(j) e where e ->> 'key' = 'q:dimension_physical_health:have')
    and (select e ->> 'dimension' from jsonb_array_elements(j) e where e ->> 'key' = 'q:reflection_identity:afraid') = 'mental_health'
    and (select e ->> 'dimension' is null and e ->> 'title' like 'Help with: %' from jsonb_array_elements(j) e where e ->> 'key' = 'q:reflection_identity:have')
    and (select e ->> 'urgency' from jsonb_array_elements(j) e where e ->> 'key' = 'area:housing') = 'soon'
    and exists (select 1 from jsonb_array_elements(j) e where e ->> 'key' = 'area:food');
  r := r || format('1 five answers -> %s suggestions (housing once; dentist and panic stay in their private areas; everyday one has no area): %s', jsonb_array_length(j), ok);

  -- 2. nothing is created until the person taps; one tap makes the need, with history, and the suggestion goes away
  execute 'reset role';
  select count(*) into n from mirror.needs where individual_id = a;
  perform set_config('role', 'authenticated', true);
  ok := n = 0;
  j := public.mirror_need_add_suggested('area:housing');
  ok := ok and j ->> 'dimension' = 'housing' and j ->> 'status' = 'identified' and j ->> 'title' = 'Help with: Shelter, housing and personal environment';
  j := public.mirror_need_add_suggested('q:reflection_identity:afraid');
  ok := ok and j ->> 'category' = 'mental_health' and (j ->> 'private')::boolean;
  ok := ok and jsonb_array_length(public.mirror_need_suggestions()) = 3;
  begin perform public.mirror_need_add_suggested('area:housing'); ok := ok and false; exception when no_data_found then null; end;
  ok := ok and (public.mirror_need_history((j ->> 'id')::uuid) -> 0 ->> 'note') = 'Added from your answers';
  r := r || format('2 nothing made until a tap; tap makes the need (private one stays private), suggestion gone, no double add: %s', ok);

  -- 3. a suggestion with no area needs the person's choice; "Not now" hides one; clearing the answer removes one
  begin perform public.mirror_need_add_suggested('q:reflection_identity:have'); ok := false; exception when invalid_parameter_value then ok := true; end;
  j := public.mirror_need_add_suggested('q:reflection_identity:have', 'work');
  ok := ok and j ->> 'dimension' = 'work';
  perform public.mirror_need_suggestion_dismiss('area:food');
  perform public.mirror_answer_clear('dimension_physical_health', 'have');
  ok := ok and jsonb_array_length(public.mirror_need_suggestions()) = 0;
  r := r || format('3 no-area suggestion needs an area; Not now hides; clearing the answer removes it; none left: %s', ok);

  -- 4. organizations never get suggestions or add from them; the download marks needs from answers
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_need_suggestions(); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.mirror_need_add_suggested('area:food'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_need_suggestion_dismiss('area:food'); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_needs();
  ok := ok and jsonb_array_length(j) = 3 and (select bool_and((e ->> 'from_your_answers')::boolean) from jsonb_array_elements(j) e);
  r := r || format('4 coordinator refused (suggestions, add, Not now); download has 3 needs, all marked from your answers: %s', ok);

  -- 5. tables closed to browsers; deleting the whole Mirror removes the set-asides too
  execute 'reset role';
  ok := not has_table_privilege('authenticated', 'mirror.need_suggestion_dismissals', 'select')
    and not has_table_privilege('service_role', 'mirror.need_suggestion_dismissals', 'truncate');
  delete from mirror.individuals where id = a;
  ok := ok and not exists (select 1 from mirror.need_suggestion_dismissals where individual_id = a);
  r := r || format('5 set-asides closed to browsers, no TRUNCATE, removed with the whole Mirror: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
