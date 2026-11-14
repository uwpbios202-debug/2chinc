-- Mirror T3.1 check: the assessment engine. Fictional people and a fictional question set; always rolled back.
do $chk$
declare
  r text[] := '{}';
  x uuid; y uuid; a uuid; sid uuid;
  j jsonb; n int; n2 int; ok boolean;
  person text := json_build_object('sub', gen_random_uuid(), 'email', 'check.a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  coordx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.cx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  coordy text := json_build_object('sub', gen_random_uuid(), 'email', 'check.cy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 0. seed
  select count(*) into n from mirror.reflections; select count(*) into n2 from mirror.dimensions;
  ok := n = 8 and n2 = 15 and (select count(*) from mirror.question_sets where kind = 'reflection') = 8;
  r := r || format('0 seed: 8 reflections, 15 dimensions, 8 reflection sets: %s', ok);

  -- setup
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK Other Org', 'other') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.a@example.invalid', 'CHECK A') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.cx@example.invalid', 'CHECK CX', 'coordinator'), (y, 'check.cy@example.invalid', 'CHECK CY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  insert into mirror.question_sets (key, kind, title) values ('check_set', 'module', 'CHECK set') returning id into sid;
  insert into mirror.reflection_questions (set_id, key, prompt, answer_type, options, category, sort) values
    (sid, 'q_text', 'Text', 'text', '[]', 'general', 1),
    (sid, 'q_choice', 'Choice', 'choice', '[{"value":"a","label":"A"},{"value":"b","label":"B"}]', 'general', 2),
    (sid, 'q_multi', 'Multi', 'multi', '[{"value":"a","label":"A"},{"value":"b","label":"B"},{"value":"c","label":"C"}]', 'general', 3),
    (sid, 'q_money', 'Money', 'money', '[]', 'general', 4),
    (sid, 'q_date', 'Date', 'date', '[]', 'general', 5),
    (sid, 'q_rating', 'Rating', 'rating', '[]', 'general', 6),
    (sid, 'q_yes', 'Yes', 'yes_no', '[]', 'general', 7),
    (sid, 'q_health', 'Health', 'long_text', '[]', 'health', 8);
  perform set_config('role', 'authenticated', true);

  -- 1. the person saves every answer type; wrong values refused
  perform set_config('request.jwt.claims', person, true);
  perform public.mirror_answer_save('check_set', 'q_text', '"  I cook  "');
  perform public.mirror_answer_save('check_set', 'q_choice', '"b"');
  perform public.mirror_answer_save('check_set', 'q_multi', '["c","a","a"]');
  perform public.mirror_answer_save('check_set', 'q_money', '"12.345"');
  perform public.mirror_answer_save('check_set', 'q_date', '"2026-01-31"');
  perform public.mirror_answer_save('check_set', 'q_rating', '4');
  perform public.mirror_answer_save('check_set', 'q_yes', 'true');
  j := public.mirror_answer_save('check_set', 'q_health', '"asthma"');
  ok := (j ->> 'answered')::int = 8;
  j := public.mirror_set_get('check_set');
  ok := ok and (select q -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_text') = 'I cook'
    and (select q -> 'answer' -> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_money') = '12.35'::jsonb
    and (select jsonb_array_length(q -> 'answer' -> 'value') from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_multi') = 2;
  begin perform public.mirror_answer_save('check_set', 'q_choice', '"z"'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_answer_save('check_set', 'q_money', '"-5"'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_answer_save('check_set', 'q_rating', '6'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_answer_save('check_set', 'q_text', '"   "'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_answer_save('check_set', 'q_date', '"soon"'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('1 every answer type saved and cleaned; wrong values refused: %s', ok);

  -- 2. the other answer states
  perform public.mirror_answer_save('check_set', 'q_yes', null, 'prefer_not');
  perform public.mirror_answer_save('check_set', 'q_date', null, 'needs_help', 'I need my papers');
  j := public.mirror_set_get('check_set');
  ok := (select q -> 'answer' ->> 'state' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_yes') = 'prefer_not'
    and (select q -> 'answer' -> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_yes') = 'null'::jsonb
    and (select q -> 'answer' ->> 'note' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_date') = 'I need my papers';
  r := r || format('2 states prefer_not / needs_help saved with note: %s', ok);

  -- 3. history: old answers kept, same answer again adds nothing, answers cannot be edited or deleted
  perform public.mirror_answer_save('check_set', 'q_text', '"I cook and sew"');
  perform public.mirror_answer_save('check_set', 'q_text', '"I cook and sew"');
  j := public.mirror_answers_history('check_set', 'q_text');
  ok := jsonb_array_length(j) = 2 and j -> 0 ->> 'value' = 'I cook and sew' and (j -> 0 ->> 'current')::boolean and not (j -> 1 ->> 'current')::boolean;
  execute 'reset role';
  begin update mirror.assessment_responses set value = '"x"' where question_id in (select id from mirror.reflection_questions where set_id = sid); ok := ok and false; exception when insufficient_privilege then null; end;
  begin delete from mirror.assessment_responses where question_id in (select id from mirror.reflection_questions where set_id = sid); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('role', 'authenticated', true);
  r := r || format('3 history kept (2 versions), unchanged answer adds none, no edit/delete: %s', ok);

  -- 4. coordinator of X without consent: general visible, health hidden, cannot edit; counting logs nothing
  perform set_config('request.jwt.claims', coordx, true);
  execute 'reset role'; select count(*) into n from mirror.audit_logs where individual_id = a; perform set_config('role', 'authenticated', true);
  j := public.mirror_sets(null, a);
  execute 'reset role'; select count(*) into n2 from mirror.audit_logs where individual_id = a; perform set_config('role', 'authenticated', true);
  ok := n2 = n and (select (s ->> 'questions')::int from jsonb_array_elements(j) s where s ->> 'key' = 'check_set') = 7;
  j := public.mirror_set_get('check_set', a);
  ok := ok and (select (q ->> 'hidden')::boolean and q -> 'answer' = 'null'::jsonb from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_health')
    and (select q -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_choice') = 'b'
    and not (select (q ->> 'can_edit')::boolean from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_choice');
  begin perform public.mirror_answer_save('check_set', 'q_text', '"x"', 'answered', null, a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_answers_history('check_set', 'q_health', a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator without consent: general seen, health hidden, no edits, counting not logged: %s', ok);

  -- 5. with the person's consent (general edit, health view): coordinator edits general, sees health, cannot edit health
  execute 'reset role';
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values
    (a, x, 'general', 'edit', 'check.a@example.invalid'), (a, x, 'health', 'view', 'check.a@example.invalid');
  perform set_config('role', 'authenticated', true);
  perform public.mirror_answer_save('check_set', 'q_rating', '5', 'answered', null, a);
  j := public.mirror_set_get('check_set', a);
  ok := (select q -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_health') = 'asthma'
    and (select q -> 'answer' ->> 'by' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'q_rating') = 'coordinator';
  begin perform public.mirror_answer_save('check_set', 'q_health', '"x"', 'answered', null, a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and action = 'view' and category = 'health';
  select count(*) into n2 from mirror.audit_logs where individual_id = a and action = 'edit' and category = 'general';
  perform set_config('role', 'authenticated', true);
  r := r || format('5 with consent: coordinator edits general (by=coordinator), sees health, cannot edit health; logged %s health views, %s edits: %s', n, n2, ok and n = 1 and n2 = 1);

  -- 6. a coordinator of another organization sees nothing
  perform set_config('request.jwt.claims', coordy, true);
  begin perform public.mirror_set_get('check_set', a); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.mirror_answer_save('check_set', 'q_text', '"x"', 'answered', null, a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('6 other organization refused: %s', ok);

  -- 7. deleting the person removes their answers (D-18), audit rows stay
  execute 'reset role';
  delete from mirror.individuals where id = a;
  select count(*) into n from mirror.assessment_responses r2 join mirror.reflection_questions q on q.id = r2.question_id where q.set_id = sid;
  select count(*) into n2 from mirror.audit_logs where individual_id = a;
  r := r || format('7 person deleted: answers left %s (0), audit rows kept %s: %s', n, n2, n = 0 and n2 > 0);

  -- 8. closed to browsers
  ok := not has_table_privilege('authenticated', 'mirror.assessment_responses', 'select') and not has_function_privilege('anon', 'public.mirror_set_get(text, uuid)', 'execute')
    and (select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'mirror' and c.relkind = 'r' and not c.relrowsecurity) = 0;
  r := r || format('8 closed to browsers, row security on every table: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
