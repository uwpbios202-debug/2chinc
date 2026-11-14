-- Mirror T8.3 check: assessments with the person, the review side (mirror_assessments_review). Counts and dates only, topics the
-- organization may see only, "together" = saved by this organization's members, "since" = the person's own later answers,
-- coordinators of the organization only (authenticator), private topics counted are logged as looks.
-- Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t83-assessments-review-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; j jsonb; e jsonb; n int; ok boolean; gq bigint;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; cx text; c1 text; cy text;
begin
  insert into auth.users (id, email) values (ua, 'check.aa@example.invalid'), (uc, 'check.acx@example.invalid'), (uy, 'check.acy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
  values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now()), (sy, uy, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.aa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.acx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.acx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc)::text;
  cy := json_build_object('sub', uy, 'email', 'check.acy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK Y', 'nonprofit') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.aa@example.invalid', 'CHECK AA', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.acx@example.invalid', 'CHECK ACX', 'coordinator'), (y, 'check.acy@example.invalid', 'CHECK ACY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  select count(*) into gq from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id
   where s.key = 'reflection_vision' and q.active and q.category = 'general';
  perform set_config('role', 'authenticated', true);

  -- the person answers one health question (later: two everyday ones) (health not shared); shares everyday topics "see and change"
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_answer_save('reflection_vision', 'health', to_jsonb('CHECKWORD walking'::text));
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform public.mirror_answer_save('reflection_vision', 'one_year', to_jsonb('CHECKWORD a job'::text));   -- today, on their own
  -- earlier days (answers can't be changed, so these two are written with their dates): 3 days ago the person's own answer,
  -- 2 days ago one saved by the coordinator with them, as mirror_answer_save writes it (their email, role coordinator)
  execute 'reset role';
  insert into mirror.assessment_responses (assessment_id, question_id, value, state, answered_by, answered_by_role, answered_at)
  select ax.id, q.id, to_jsonb(v.w), 'answered', v.who, v.role, now() - v.ago
    from mirror.assessments ax join mirror.question_sets s on s.id = ax.set_id
    join (values ('person', 'CHECKWORD kind', 'check.aa@example.invalid', 'self', interval '3 days'),
                 ('where_live', 'CHECKWORD near family', 'check.acx@example.invalid', 'coordinator', interval '2 days')) v(k, w, who, role, ago) on true
    join mirror.reflection_questions q on q.set_id = s.id and q.key = v.k
   where ax.individual_id = a and s.key = 'reflection_vision';
  perform set_config('role', 'authenticated', true);

  -- 1. the organization's list: 3 everyday answers (health left out), 1 together, 1 since, 1 set together
  perform set_config('request.jwt.claims', cx, true);
  select v into e from jsonb_array_elements(public.mirror_assessments_review(x) -> 'people') v where v ->> 'id' = a::text;
  ok := (e ->> 'answered')::int = 3 and (e ->> 'with_you')::int = 1 and (e ->> 'since_together')::int = 1
    and (e ->> 'sets_together')::int = 1 and (e ->> 'sets_started')::int = 1 and e ->> 'last_together' is not null;
  r := r || format('1 list: 3 everyday answers (health not counted), 1 together, 1 since, 1 set together: %s (%s)', ok, e);

  -- 2. one person: the Vision set counts only everyday questions, says private questions exist (no number)
  j := public.mirror_assessments_review(x, a);
  select v into e from jsonb_array_elements(j -> 'sets') v where v ->> 'key' = 'reflection_vision';
  ok := (e ->> 'questions')::bigint = gq and (e ->> 'answered')::int = 3 and (e ->> 'with_you')::int = 1 and (e ->> 'times_together')::int = 1
    and (e ->> 'since_together')::int = 1 and (e ->> 'private_unshared')::boolean
    and not exists (select 1 from jsonb_array_elements(j -> 'sets') v where v ->> 'key' = 'functional_seeing');
  r := r || format('2 one person: everyday questions only, private ones flagged without a number, health-only sets not listed: %s', ok);

  -- 3. the person changes the coordinator's answer: no longer "with you" now, but the time together stays; since = 2; no words returned
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_answer_save('reflection_vision', 'where_live', to_jsonb('CHECKWORD my own place'::text));
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_assessments_review(x, a);
  select v into e from jsonb_array_elements(j -> 'sets') v where v ->> 'key' = 'reflection_vision';
  ok := (e ->> 'with_you')::int = 0 and (e ->> 'since_together')::int = 2 and e ->> 'last_together' is not null
    and position('CHECKWORD' in j::text) = 0 and position('CHECKWORD' in public.mirror_assessments_review(x)::text) = 0;
  r := r || format('3 after the person''s change: 0 with you, 2 since, the time together kept, no answer words in either result: %s', ok);

  -- 4. refused: the same coordinator without the authenticator; another organization's coordinator for this person; not on their list
  ok := true;
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_assessments_review(x); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', cy, true);
  begin perform public.mirror_assessments_review(y, a); ok := false; exception when others then null; end;
  ok := ok and jsonb_array_length(public.mirror_assessments_review(y) -> 'people') = 0;
  begin perform public.mirror_assessments_review(x); ok := false; exception when others then null; end;
  r := r || format('4 refused without the authenticator, for another organization, and for an organization they do not belong to: %s', ok);

  -- 5. once health is shared, it is counted and the look is logged for the person
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'health', 'view');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_assessments_review(x, a);
  select v into e from jsonb_array_elements(j -> 'sets') v where v ->> 'key' = 'reflection_vision';
  execute 'reset role';
  select count(*) into n from mirror.audit_logs l where l.individual_id = a and l.organization_id = x and l.table_name = 'workspace_assessments'
     and l.category = 'health';
  ok := (e ->> 'answered')::int = 4 and n >= 1
    and not exists (select 1 from mirror.audit_logs l where l.individual_id = a and l.table_name = 'workspace_assessments' and l.category = 'general');
  r := r || format('5 health shared: counted (4 answers) and logged as a look (%s); everyday topics not logged: %s', n, ok);

  -- 6. the coordinator goes over one more question with them today (through mirror_answer_save): with you 1, nothing since, 2 days together
  perform set_config('role', 'authenticated', true);
  perform public.mirror_answer_save('reflection_vision', 'learn', to_jsonb('CHECKWORD cooking'::text), 'answered', null, a);
  select v into e from jsonb_array_elements(public.mirror_assessments_review(x, a) -> 'sets') v where v ->> 'key' = 'reflection_vision';
  ok := (e ->> 'with_you')::int = 1 and (e ->> 'since_together')::int = 0 and (e ->> 'times_together')::int = 2 and (e ->> 'answered')::int = 5;
  r := r || format('6 a save with the person today counts as together (2 days together, nothing since): %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
