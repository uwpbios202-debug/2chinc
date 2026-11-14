-- Check for Phase 3 finding 7 (migration 20261119280000): the counts mirror_answer_save returns cover only what the caller may see.
-- Runs after the migration in ONE transaction that always ends in an error, so nothing is kept (fictional people only):
--   sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
-- reflection_identity has 14 active questions: 10 general, 2 mental_health, 1 health, 1 financial.
do $chk$
declare
  r text[] := '{}'; x uuid; p uuid; j jsonb; n0 int; n1 int; ok boolean;
  pp text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p3f7@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cc text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p3f7c@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.p3f7c@example.invalid', 'CHECK Coordinator', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p3f7@example.invalid', 'CHECK Person') returning id into p;
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, p, 'active');
  perform set_config('role', 'authenticated', true);

  -- the person answers one general and two private questions, and lets the organization change general answers only
  perform set_config('request.jwt.claims', pp, true);
  perform public.mirror_answer_save('reflection_identity', 'about_me', null, 'prefer_not');
  perform public.mirror_answer_save('reflection_identity', 'afraid', null, 'prefer_not');
  j := public.mirror_answer_save('reflection_identity', 'health_now', null, 'unknown');
  ok := (j ->> 'answered')::int = 3 and (j ->> 'questions')::int = 14;
  r := r || format('1 the person sees every count (3 answered of 14): %s (%s of %s)', ok, j ->> 'answered', j ->> 'questions');
  perform public.mirror_my_consent_set(x, 'general', 'edit');

  -- the coordinator saves a general answer: counts leave out the 2 private answers and the 4 private questions
  perform set_config('request.jwt.claims', cc, true);
  execute 'reset role';
  select count(*) into n0 from mirror.audit_logs where individual_id = p;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cc, true);
  j := public.mirror_answer_save('reflection_identity', 'proud', null, 'unknown', null, p);
  ok := (j ->> 'answered')::int = 2 and (j ->> 'questions')::int = 10;
  r := r || format('2 the coordinator sees only general counts (2 answered of 10): %s (%s of %s)', ok, j ->> 'answered', j ->> 'questions');

  -- counting is not a look: the coordinator's save added only its edit entry (1), no view entries
  execute 'reset role';
  select count(*) into n1 from mirror.audit_logs where individual_id = p;
  ok := n1 - n0 = 1 and not exists (select 1 from mirror.audit_logs where individual_id = p and action = 'view');
  r := r || format('3 no "looked" entries from counting (new entries %s, expected 1): %s', n1 - n0, ok);

  -- the coordinator still cannot save a private answer
  -- (its "refused" log entry is undone together with the error: existing mirror.require behavior, reported separately)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cc, true);
  begin perform public.mirror_answer_save('reflection_identity', 'afraid', null, 'unknown', null, p); ok := false;
  exception when insufficient_privilege then ok := true; end;
  r := r || format('4 the coordinator is still refused a private question: %s', ok);
  execute 'reset role';

  -- the person's own count after the coordinator's save: 4 of 14
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  j := public.mirror_answer_save('reflection_identity', 'about_me', null, 'prefer_not');
  ok := (j ->> 'answered')::int = 4 and (j ->> 'questions')::int = 14;
  r := r || format('5 the person now sees 4 of 14 (unchanged answer saved again adds nothing): %s (%s of %s)', ok, j ->> 'answered', j ->> 'questions');
  execute 'reset role';

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
