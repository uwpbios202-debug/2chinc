-- Phase 2 fix 2 check: consent recorded on paper / out loud for a person without email; the coordinator can then enter answers;
-- not allowed for people who can sign in, or by other organizations; note required; withdrawal works; all logged. Always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; b uuid; j jsonb; n int; ok boolean;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.rc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cy text := json_build_object('sub', gen_random_uuid(), 'email', 'check.ry@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pb text := json_build_object('sub', gen_random_uuid(), 'email', 'check.rb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK Other Org', 'other') returning id into y;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.rc@example.invalid', 'CHECK Coordinator', 'coordinator'), (y, 'check.ry@example.invalid', 'CHECK Other', 'coordinator');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  a := public.mirror_person_add(jsonb_build_object('organization_id', x, 'preferred_name', 'CHECK No Email'));
  b := public.mirror_person_add(jsonb_build_object('organization_id', x, 'preferred_name', 'CHECK Has Email', 'email', 'check.rb@example.invalid'));

  -- 1. without a recorded choice the coordinator cannot enter answers for the person without email
  begin perform public.mirror_answer_save('reflection_identity', 'proud', '"x"', 'answered', null, a); ok := false; exception when insufficient_privilege then ok := true; end;
  r := r || format('1 before: the coordinator cannot enter answers for a person without email: %s', ok);

  -- 2. record general "see and change" on paper; now the coordinator enters an answer, marked as entered by the coordinator
  j := public.mirror_consent_record(a, x, 'general', 'edit', 'paper', 'Signed form in the paper file, 11/13');
  ok := j #>> '{sharing,general,access}' = 'edit' and j #>> '{sharing,general,method}' = 'paper' and j #>> '{sharing,general,by}' = 'CHECK Coordinator' and (j ->> 'can_record')::boolean;
  perform public.mirror_answer_save('reflection_identity', 'proud', '"My garden"', 'answered', null, a);
  ok := ok and (select q -> 'answer' ->> 'by' from jsonb_array_elements(public.mirror_set_get('reflection_identity', a) -> 'questions') q where q ->> 'key' = 'proud') = 'coordinator';
  r := r || format('2 recorded on paper -> the coordinator enters answers for them (marked as the coordinator''s): %s', ok);

  -- 3. refusals: no note; a person who can sign in; another organization; an unknown way of agreeing
  begin perform public.mirror_consent_record(a, x, 'health', 'view', 'spoken', ''); ok := false; exception when invalid_parameter_value then ok := true; end;
  begin perform public.mirror_consent_record(a, x, 'health', 'view', 'online', 'said yes'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_consent_record(b, x, 'general', 'edit', 'paper', 'Signed form in file'); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', cy, true);
  begin perform public.mirror_consent_record(a, x, 'general', 'edit', 'paper', 'Signed form in file'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_consents_recorded(a, x); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('3 refused: no note, "online" by a coordinator, a person who can sign in, another organization: %s', ok);

  -- 4. withdrawal recorded out loud: the coordinator can no longer enter answers
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_consent_record(a, x, 'general', 'none', 'spoken', 'Told me on the phone to stop, 11/13');
  ok := j -> 'sharing' = '{}'::jsonb;
  begin perform public.mirror_answer_save('reflection_identity', 'proud', '"y"', 'answered', null, a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and action in ('consent_grant', 'consent_revoke');
  r := r || format('4 withdrawal recorded out loud -> no more edits; grant and withdrawal logged (%s, 2): %s', n, ok and n = 2);

  -- 5. if the person gets a sign-in later, Settings shows the recorded choice and who recorded it
  update mirror.individuals set auth_email = 'check.later@example.invalid' where id = a;
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by, method, note) values (a, x, 'health', 'view', 'check.rc@example.invalid', 'spoken', 'Said yes in person');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.later@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := public.mirror_my_settings();
  ok := j #>> '{organizations,0,sharing_detail,health,method}' = 'spoken' and j #>> '{organizations,0,sharing_detail,health,by}' = 'CHECK Coordinator';
  execute 'reset role';
  r := r || format('5 the person later sees "recorded by CHECK Coordinator, out loud" in Settings: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
