-- Check for Phase 3 finding 8 (migration 20261119281000). Runs after the migration in ONE transaction that always ends in an error,
-- so nothing is kept (fictional people only): sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; ok boolean; n int; p uuid;
  pp text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p3f8@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1 service_role no longer holds TRUNCATE; anon and authenticated still hold nothing on the table
  ok := not has_table_privilege('service_role', 'mirror.assessment_responses', 'TRUNCATE')
    and has_table_privilege('service_role', 'mirror.assessment_responses', 'SELECT')
    and not has_table_privilege('anon', 'mirror.assessment_responses', 'SELECT')
    and not has_table_privilege('authenticated', 'mirror.assessment_responses', 'SELECT');
  r := r || format('1 service_role cannot truncate (keeps SELECT); anon/authenticated no access: %s', ok);

  -- a fictional person with one answer
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p3f8@example.invalid', 'CHECK Person') returning id into p;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  perform public.mirror_answer_save('reflection_identity', 'about_me', null, 'prefer_not');
  execute 'reset role';
  select count(*) into n from mirror.assessment_responses;

  -- 2 service_role is refused by the grant
  execute 'set local role service_role';
  begin execute 'truncate mirror.assessment_responses'; ok := false; exception when insufficient_privilege then ok := true; end;
  execute 'reset role';
  r := r || format('2 TRUNCATE as service_role refused: %s', ok);

  -- 3 the owner is refused by the trigger, directly and through TRUNCATE ... CASCADE on assessments; rows kept
  begin execute 'truncate mirror.assessment_responses'; ok := false; exception when insufficient_privilege then ok := true; end;
  begin execute 'truncate mirror.assessments cascade'; ok := false; exception when insufficient_privilege then ok := ok and true; end;
  ok := ok and (select count(*) from mirror.assessment_responses) = n and n > 0;
  r := r || format('3 TRUNCATE as owner refused (direct and cascade), rows kept: %s', ok);

  -- 4 saving still works; UPDATE of an answer and single DELETE still refused; deleting the whole Mirror still removes its answers
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pp, true);
  perform public.mirror_answer_save('reflection_identity', 'about_me', null, 'unknown');
  execute 'reset role';
  ok := (select count(*) from mirror.assessment_responses r2 join mirror.assessments a on a.id = r2.assessment_id where a.individual_id = p) = 2;
  begin update mirror.assessment_responses set note = 'x' where assessment_id in (select id from mirror.assessments where individual_id = p); ok := false;
  exception when insufficient_privilege then null; end;
  begin delete from mirror.assessment_responses where assessment_id in (select id from mirror.assessments where individual_id = p); ok := false;
  exception when insufficient_privilege then null; end;
  delete from mirror.individuals where id = p;
  ok := ok and not exists (select 1 from mirror.assessments where individual_id = p);
  r := r || format('4 saves work; UPDATE and single DELETE refused; whole-Mirror delete still cascades: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
