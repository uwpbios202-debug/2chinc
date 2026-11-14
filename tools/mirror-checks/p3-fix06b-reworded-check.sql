-- Check for P3-06b (migration 20261119286000): the answering screen learns when an answer was given to an earlier wording.
-- Fictional person; the rewording is undone too (always rolled back): sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; ok boolean; qid uuid; j jsonb; a jsonb; qq jsonb;
  pp text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p306b@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1 the view keeps its 10 columns in order and adds question_version last
  ok := (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'mirror' and table_name = 'current_answers')
        = 'individual_id,set_key,kind,question_key,category,value,state,note,answered_by_role,answered_at,question_version';
  r := r || format('1 current_answers: same 10 columns in order, question_version added last: %s', ok);

  insert into mirror.individuals (auth_email, preferred_name) values ('check.p306b@example.invalid', 'CHECK Person');
  select q.id into qid from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id
   where s.key = 'reflection_identity' and q.key = 'about_me';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  perform public.mirror_answer_save('reflection_identity', 'about_me', '"My answer"');

  -- 2 before any rewording: version 1 on question and answer, not reworded
  j := public.mirror_set_get('reflection_identity');
  select x into qq from jsonb_array_elements(j -> 'questions') x where x ->> 'key' = 'about_me';
  a := qq -> 'answer';
  ok := (qq ->> 'version')::int = 1 and (a ->> 'version')::int = 1 and (a ->> 'reworded')::boolean = false and a ->> 'value' = 'My answer';
  r := r || format('2 unchanged question: question v1, answer v1, reworded false: %s', ok);

  -- 3 after rewording: question v2, answer still v1 and reworded true; other questions unaffected
  execute 'reset role';
  update mirror.reflection_questions set prompt = 'CHECK reworded prompt' where id = qid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  j := public.mirror_set_get('reflection_identity');
  select x into qq from jsonb_array_elements(j -> 'questions') x where x ->> 'key' = 'about_me';
  a := qq -> 'answer';
  ok := (qq ->> 'version')::int = 2 and qq ->> 'prompt' = 'CHECK reworded prompt' and (a ->> 'version')::int = 1 and (a ->> 'reworded')::boolean = true
    and not exists (select 1 from jsonb_array_elements(j -> 'questions') x where x ->> 'key' <> 'about_me' and (x ->> 'version')::int <> 1);
  r := r || format('3 reworded question: question v2, answer v1 flagged reworded; others still v1: %s', ok);

  -- 4 answering again clears the flag; history keeps the old wording for the old answer
  perform public.mirror_answer_save('reflection_identity', 'about_me', '"New answer"');
  j := public.mirror_set_get('reflection_identity');
  select x -> 'answer' into a from jsonb_array_elements(j -> 'questions') x where x ->> 'key' = 'about_me';
  j := public.mirror_answers_history('reflection_identity', 'about_me');
  ok := (a ->> 'reworded')::boolean = false and (a ->> 'version')::int = 2
    and (j -> 1 ->> 'reworded')::boolean and j -> 1 ->> 'question' <> 'CHECK reworded prompt';
  execute 'reset role';
  r := r || format('4 answer again: flag cleared (v2); history keeps the earlier wording for the old answer: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
