-- Mirror T3.5 check: 15 life-area sets of 10 questions; private areas private; a person answers; a coordinator without consent
-- sees a general area but not a private one. Always rolled back.
do $chk$
declare r text[] := '{}'; x uuid; a uuid; j jsonb; n int; ok boolean;
begin
  select count(*) into n from mirror.question_sets where kind = 'dimension';
  r := r || format('1 dimension sets: %s (15)', n);
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'dimension';
  r := r || format('2 dimension questions: %s (195) in all: 150 + 45 whole-person questions of Phase 11', n);
  r := r || ('3 private areas: ' || (select string_agg(distinct s.dimension_key || '=' || q.category, ', ') from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'dimension' and q.category <> 'general' and q.key <> 'cost'));
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'dimension' and q.key = 'cost' and q.category <> 'financial';
  r := r || format('4 cost questions not financial: %s (0)', n);

  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.d@example.invalid', 'CHECK D') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.dc@example.invalid', 'CHECK DC', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.d@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  perform public.mirror_answer_save('dimension_housing', 'condition', '2');
  perform public.mirror_answer_save('dimension_housing', 'help_wanted', '"now"');
  perform public.mirror_answer_save('dimension_physical_health', 'have', '"a clinic nearby"');
  j := public.mirror_sets('dimension');
  ok := jsonb_array_length(j) = 15 and (select (s ->> 'answered')::int from jsonb_array_elements(j) s where s ->> 'dimension' = 'housing') = 2;
  r := r || format('5 person answers housing and health; 15 areas listed: %s', ok);

  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.dc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := public.mirror_set_get('dimension_housing', a);
  ok := (select q -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'help_wanted') = 'now'
    and (select (q ->> 'hidden')::boolean from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'cost');
  begin perform public.mirror_set_get('dimension_physical_health', a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  r := r || format('6 coordinator without consent: housing seen (cost hidden), physical health refused: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
