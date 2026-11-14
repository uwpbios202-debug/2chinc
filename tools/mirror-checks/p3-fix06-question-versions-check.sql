-- Check for Phase 3 finding 6 (migration 20261119282000): question wording is versioned and every answer keeps the wording it was
-- given to. Runs after the migration in ONE transaction that always ends in an error, so nothing is kept (fictional person only;
-- the question rewording below is undone too): sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; ok boolean; p uuid; qid uuid; old_prompt text; j jsonb; e jsonb; n int;
  pp text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p3f6@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1 starting point: every question is version 1 with a matching wording row; every existing answer is version 1
  ok := (select count(*) from mirror.reflection_questions) = (select count(*) from mirror.question_versions)
    and not exists (select 1 from mirror.reflection_questions where version <> 1)
    and not exists (select 1 from mirror.reflection_questions q join mirror.question_versions v on v.question_id = q.id and v.version = 1
                    where (v.prompt, v.help, v.answer_type, v.options, v.category) is distinct from (q.prompt, q.help, q.answer_type, q.options, q.category))
    and not exists (select 1 from mirror.assessment_responses where question_version <> 1)
    and not has_table_privilege('authenticated', 'mirror.question_versions', 'SELECT')
    and not has_table_privilege('anon', 'mirror.question_versions', 'SELECT');
  select count(*) into n from mirror.question_versions;
  r := r || format('1 %s questions = %s wording rows, all version 1 and identical; answers all version 1; no browser access: %s',
    (select count(*) from mirror.reflection_questions), n, ok);

  -- a fictional person answers "about_me" (version 1)
  select q.id, q.prompt into qid, old_prompt from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id
   where s.key = 'reflection_identity' and q.key = 'about_me';
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p3f6@example.invalid', 'CHECK Person') returning id into p;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  perform public.mirror_answer_save('reflection_identity', 'about_me', '"First answer"');
  execute 'reset role';

  -- 2 rewording raises the version and records it; a sort-only change or a hand-set version does not
  update mirror.reflection_questions set prompt = 'CHECK reworded: who are you now?' where id = qid;
  ok := (select version from mirror.reflection_questions where id = qid) = 2
    and (select prompt from mirror.question_versions where question_id = qid and version = 1) = old_prompt
    and (select prompt from mirror.question_versions where question_id = qid and version = 2) = 'CHECK reworded: who are you now?';
  update mirror.reflection_questions set sort = sort + 1 where id = qid;
  update mirror.reflection_questions set version = 9 where id = qid;
  ok := ok and (select version from mirror.reflection_questions where id = qid) = 2
    and (select count(*) from mirror.question_versions where question_id = qid) = 2;
  r := r || format('2 reword -> version 2 recorded, version 1 kept; sort change and hand-set version leave it at 2: %s', ok);

  -- 3 a new answer is stored against version 2; history shows each answer with the wording it was given to
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  perform public.mirror_answer_save('reflection_identity', 'about_me', '"Second answer"');
  j := public.mirror_answers_history('reflection_identity', 'about_me');
  ok := jsonb_array_length(j) = 2
    and (j -> 0 ->> 'version')::int = 2 and (j -> 0 ->> 'reworded')::boolean = false and j -> 0 ->> 'question' = 'CHECK reworded: who are you now?'
    and (j -> 0 ->> 'current')::boolean
    and (j -> 1 ->> 'version')::int = 1 and (j -> 1 ->> 'reworded')::boolean = true and j -> 1 ->> 'question' = old_prompt
    and j -> 1 ->> 'value' = 'First answer';
  r := r || format('3 history: new answer v2 (current), old answer v1 with the old wording and reworded=true: %s', ok);

  -- 4 the download carries the wording each answer was given to
  j := public.mirror_my_export();
  ok := exists (select 1 from jsonb_array_elements(j -> 'answers') e2 where e2 ->> 'answer' = 'First answer' and e2 ->> 'question' = old_prompt and (e2 ->> 'question_version')::int = 1)
    and exists (select 1 from jsonb_array_elements(j -> 'answers') e2 where e2 ->> 'answer' = 'Second answer' and e2 ->> 'question' = 'CHECK reworded: who are you now?' and (e2 ->> 'question_version')::int = 2);
  execute 'reset role';
  r := r || format('4 download: each answer with its own wording and version: %s', ok);

  -- 5 the wording history and the stored version cannot be changed
  ok := true;
  begin update mirror.question_versions set prompt = 'x' where question_id = qid and version = 1; ok := false; exception when insufficient_privilege then null; end;
  begin delete from mirror.question_versions where question_id = qid and version = 1; ok := false; exception when insufficient_privilege then null; end;
  begin execute 'truncate mirror.question_versions cascade'; ok := false; exception when insufficient_privilege then null; end;
  begin
    update mirror.assessment_responses set superseded_at = now(), question_version = 1   -- the current answer is version 2
     where question_id = qid and superseded_at is null and assessment_id in (select id from mirror.assessments where individual_id = p);
    ok := false;
  exception when insufficient_privilege then null; end;
  insert into mirror.assessment_responses (assessment_id, question_id, value, state, answered_by, answered_by_role, question_version, superseded_at)
  select a.id, qid, '"x"', 'answered', 'check', 'self', 1, now() from mirror.assessments a where a.individual_id = p limit 1;
  ok := ok and (select question_version from mirror.assessment_responses where answered_by = 'check' and question_id = qid) = 2;
  r := r || format('5 wording rows: UPDATE, DELETE, TRUNCATE refused; answer version cannot be changed; a hand-given version is replaced by the current one: %s', ok);

  -- 6 deleting the whole Mirror still removes its answers (and leaves the wording history)
  delete from mirror.individuals where id = p;
  ok := not exists (select 1 from mirror.assessments where individual_id = p)
    and (select count(*) from mirror.question_versions where question_id = qid) = 2;
  r := r || format('6 whole-Mirror delete still cascades; wording history kept: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
