-- Mirror Phase 5 check (T5.1 functional, T5.2 housing). Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; n int; ok boolean; v_jail uuid; v_fa uuid;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p5a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pb text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p5b@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.c5x@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p5a@example.invalid', 'CHECK P5A') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p5b@example.invalid', 'CHECK P5B') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.c5x@example.invalid', 'CHECK C5X', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');

  -- 0. seed and closure: 11 functional sets x 5 questions, 7 options; 6 tables locked to service_role, row security on
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'functional' and q.active;
  ok := n = 55 and (select count(*) from mirror.question_sets where kind = 'functional') = 11 and (select count(*) from mirror.housing_options) = 7;
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
    where s.nspname = 'mirror' and c.relname in ('functional_assessments', 'adl_assessments', 'iadl_assessments', 'housing_options', 'housing_profiles', 'housing_history')
      and c.relrowsecurity and not has_table_privilege('authenticated', c.oid, 'select') and not has_table_privilege('anon', c.oid, 'select')
      and not has_table_privilege('authenticated', c.oid, 'insert');
  ok := ok and n = 6;
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.proname in ('mirror_fa_get', 'mirror_fa_save', 'mirror_fa_finish', 'mirror_fa_review', 'mirror_housing_get', 'mirror_housing_save',
      'mirror_housing_history_save', 'mirror_housing_history_delete', 'mirror_housing_review', 'mirror_my_export_living')
      and p.prosecdef and p.proconfig is not null and not has_function_privilege('anon', p.oid, 'execute');
  r := r || format('0 seed 55 questions / 11 areas / 7 options; 6 tables closed; 10 functions definer, fixed path, not anon: %s', ok and n = 10);

  perform set_config('role', 'authenticated', true);

  -- 1. the person: level + preference beside it, finish, history kept, a new check-in starts fresh
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_fa_save('adl', 'bathing', 'with_device', 'tools', 'grab bar would help');
  j := public.mirror_fa_save('iadl', 'meal_prep', 'independent', 'as_now');
  ok := j -> 'adl' -> 'bathing' ->> 'level' = 'with_device' and j -> 'adl' -> 'bathing' ->> 'preference' = 'tools' and (j ->> 'self_report')::boolean;
  begin perform public.mirror_fa_save('adl', 'bathing', 'very_bad'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_fa_save('adl', 'flying', 'independent'); ok := ok and false; exception when invalid_parameter_value then null; end;
  v_fa := (public.mirror_fa_finish() ->> 'id')::uuid;
  perform public.mirror_fa_save('adl', 'dressing', 'some_help', 'more_on_own');
  j := public.mirror_fa_get();
  ok := ok and jsonb_array_length(j -> 'history') = 1 and j -> 'open' -> 'adl' ? 'dressing' and not (j -> 'open' -> 'adl' ? 'bathing')
    and j -> 'last' -> 'adl' -> 'bathing' ->> 'note' = 'grab bar would help' and not (j ->> 'can_flag')::boolean;
  begin perform public.mirror_fa_review(true, 'x'); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('1 person: level + own preference, bad choices refused, finish keeps history, new check-in fresh, cannot mark review: %s', ok);

  -- 2. a finished check-in never changes (even for the server role)
  execute 'reset role';
  begin update mirror.adl_assessments set level = 'full_help' where functional_assessment_id = v_fa; ok := false; exception when insufficient_privilege then ok := true; end;
  begin update mirror.functional_assessments set completed_at = null where id = v_fa; ok := ok and false; exception when insufficient_privilege then null; end;
  begin delete from mirror.functional_assessments where id = v_fa; ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('2 finished check-in frozen (row change, reopen, delete refused): %s', ok);
  perform set_config('role', 'authenticated', true);

  -- 3. housing by the person, with private parts (jail = legal, accessibility = health, criminal record = legal)
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_housing_save('{"current_arrangement": "shelter", "preferred": ["independent", "permanent_supportive"],
    "barriers": {"keys": ["credit", "criminal_record"], "note": "working on it"}, "accessibility": {"keys": ["no_stairs"], "note": null}}');
  v_jail := (public.mirror_housing_history_save('{"arrangement": "jail", "from_on": "2020-01-01", "to_on": "2021-06-30"}') ->> 'id')::uuid;
  perform public.mirror_housing_history_save('{"arrangement": "renting", "from_on": "2021-07-01", "city": "Milwaukee"}');
  begin perform public.mirror_housing_save('{"preferred": ["castle"]}'); ok := false; exception when invalid_parameter_value then ok := true; end;
  begin perform public.mirror_housing_history_save('{"arrangement": "renting", "from_on": "2022-01-01", "to_on": "2021-01-01"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  j := public.mirror_housing_get();
  ok := ok and j -> 'profile' -> 'preferred' = '["independent", "permanent_supportive"]'::jsonb and jsonb_array_length(j -> 'history') = 2
    and j -> 'profile' -> 'accessibility' -> 'keys' = '["no_stairs"]'::jsonb and (j -> 'profile' -> 'barriers' ->> 'hidden')::int = 0;
  begin perform public.mirror_housing_review(true, 'x'); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('3 person: profile, options, history, bad option and dates refused, sees all own parts, cannot mark review: %s', ok);

  -- 4. coordinator, nothing shared beyond the default general view: housing general parts only; functional refused
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_housing_get(a);
  ok := jsonb_array_length(j -> 'history') = 1 and (j ->> 'history_hidden')::int = 1 and (j -> 'profile' -> 'barriers' ->> 'hidden')::int = 1
    and j -> 'profile' -> 'barriers' -> 'keys' = '["credit"]'::jsonb and (j -> 'profile' -> 'accessibility' ->> 'private')::boolean and not (j ->> 'can_edit')::boolean;
  begin perform public.mirror_fa_get(a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and actor_role = 'coordinator' and table_name = 'housing_profiles' and action = 'refused';
  perform set_config('role', 'authenticated', true);
  ok := ok and n = 0;   -- fix 20261119302000: topics never shared are probed quietly, not logged as refusals
  begin perform public.mirror_housing_save('{"current_note": "x"}', a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator without consent: legal/health parts hidden (counted, no refusal rows), functional refused, cannot save: %s', ok);

  -- 5. person shares general edit: coordinator saves barriers; the hidden criminal record is kept; accessibility and jail row refused
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_housing_save('{"barriers": {"keys": ["credit", "waitlists"], "note": "on 2 lists"}}', a);
  begin perform public.mirror_housing_save('{"accessibility": {"keys": []}}', a); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.mirror_housing_history_delete(v_jail, a); ok := ok and false; exception when insufficient_privilege then null; end;
  perform public.mirror_housing_review(true, 'options counselor could help', a);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_housing_get();
  ok := ok and j -> 'profile' -> 'barriers' -> 'keys' @> '["criminal_record", "credit", "waitlists"]'::jsonb and jsonb_array_length(j -> 'profile' -> 'barriers' -> 'keys') = 3
    and j -> 'profile' -> 'accessibility' -> 'keys' = '["no_stairs"]'::jsonb and jsonb_array_length(j -> 'history') = 2
    and (j -> 'profile' ->> 'professional_review_needed')::boolean and j -> 'profile' ->> 'review_by' = 'coordinator';
  r := r || format('5 coordinator with general edit: saves, private parts kept untouched, cannot change them, marks review; person sees it: %s', ok);

  -- 6. person shares health edit: coordinator opens functional, works on its own check-in, marks review; person sees the mark
  perform public.mirror_my_consent_set(x, 'health', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_fa_get(a);
  ok := (j ->> 'can_flag')::boolean and j ->> 'open' is null and jsonb_array_length(j -> 'history') = 1;
  j := public.mirror_fa_save('iadl', 'medication', 'some_help', 'some_help', null, a);
  ok := ok and not (j ->> 'self_report')::boolean and j ->> 'by' = 'coordinator';
  perform public.mirror_fa_finish(a);
  perform public.mirror_fa_review(true, 'nurse visit could help', a);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_fa_get();
  ok := ok and (j -> 'review' ->> 'needed')::boolean and jsonb_array_length(j -> 'history') = 2 and j -> 'open' -> 'adl' ? 'dressing';
  r := r || format('6 coordinator with health edit: own check-in beside the person''s, marks review; person sees it, own open check-in untouched: %s', ok);

  -- 7. another person sees nothing of A; A's export holds everything; looks and changes by the coordinator are audited
  perform set_config('request.jwt.claims', pb, true);
  begin perform public.mirror_fa_get(a); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.mirror_housing_get(a); ok := ok and false; exception when insufficient_privilege then null; end;
  j := public.mirror_housing_get();
  ok := ok and j ->> 'profile' is null and jsonb_array_length(j -> 'history') = 0;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_living();
  ok := ok and jsonb_array_length(j -> 'everyday_activities') = 3 and jsonb_array_length(j -> 'housing_history') = 2
    and j -> 'housing_profile' -> 'preferred' = '["independent", "permanent_supportive"]'::jsonb and not (j -> 'housing_profile' ? 'individual_id') and not (j -> 'housing_profile' ? 'preferred_option_ids');
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and actor_role = 'coordinator'
    and table_name in ('functional_assessments', 'iadl_assessments', 'housing_profiles', 'housing_history') and action in ('view', 'edit');
  r := r || format('7 other person refused, export complete, coordinator looks/changes audited (%s rows): %s', n, ok and n >= 6);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
