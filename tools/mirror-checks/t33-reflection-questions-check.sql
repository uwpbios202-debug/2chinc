-- Mirror T3.3 check: the 94 reflection questions load where they belong and a fictional person can answer them. Always rolled back.
do $chk$
declare r text[] := '{}'; a uuid; j jsonb; n int; ok boolean;
begin
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'reflection';
  r := r || format('1 questions loaded: %s (94)', n);
  r := r || ('2 per reflection: ' || (select string_agg(s.reflection_key || ' ' || c, ', ' order by s.sort) from (
      select s.reflection_key, s.sort, count(q.id) c from mirror.question_sets s left join mirror.reflection_questions q on q.set_id = s.id
      where s.kind = 'reflection' group by 1, 2) s));
  r := r || ('3 private questions: ' || (select string_agg(q.key || '=' || q.category, ', ') from mirror.reflection_questions q where q.category <> 'general'));
  select count(*) into n from mirror.reflection_questions where answer_type in ('choice', 'multi') and jsonb_array_length(options) < 2;
  r := r || format('4 choice questions without options: %s (0)', n);

  insert into mirror.individuals (auth_email, preferred_name) values ('check.q@example.invalid', 'CHECK Q') returning id into a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.q@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  perform public.mirror_answer_save('reflection_identity', 'living_now', '"with_others"');
  perform public.mirror_answer_save('reflection_identity', 'health_now', '3');
  perform public.mirror_answer_save('reflection_assets', 'can_do', '["cooking","childcare"]');
  perform public.mirror_answer_save('reflection_needs', 'help_areas', '["housing","work"]');
  perform public.mirror_answer_save('reflection_function', 'paperwork', '"want_help"');  -- bills retired 11/13 (P5-03)
  j := public.mirror_sets('reflection');
  ok := (select (s ->> 'answered')::int from jsonb_array_elements(j) s where s ->> 'reflection' = 'identity') = 2
    and (select (s ->> 'questions')::int from jsonb_array_elements(j) s where s ->> 'reflection' = 'identity') = 14;
  j := public.mirror_set_get('reflection_identity');
  ok := ok and jsonb_array_length(j -> 'questions') = 14 and (select bool_and(not (q ->> 'hidden')::boolean) from jsonb_array_elements(j -> 'questions') q);
  execute 'reset role';
  r := r || format('5 a person answers choice, rating, multi; counts 2 of 14; sees all own questions: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
