-- Mirror T3.6 check: the person's own privacy controls. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; n int; ok boolean;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.pa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pb text := json_build_object('sub', gen_random_uuid(), 'email', 'check.pb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.cx6@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.pa@example.invalid', 'CHECK PA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.pb@example.invalid', 'CHECK PB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.cx6@example.invalid', 'CHECK CX6', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the person shares health with the organization: the coordinator can now open a private area; withdrawing closes it again
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_answer_save('dimension_physical_health', 'have', '"a clinic"');
  perform public.mirror_my_consent_set(x, 'health', 'view');
  j := public.mirror_my_settings();
  ok := (j -> 'organizations' -> 0 -> 'sharing' ->> 'health') = 'view';
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and (select q -> 'answer' ->> 'value' from jsonb_array_elements(public.mirror_set_get('dimension_physical_health', a) -> 'questions') q where q ->> 'key' = 'have') = 'a clinic';
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'health', 'none');
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_set_get('dimension_physical_health', a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('1 share health -> coordinator sees it; withdraw -> refused again: %s', ok);

  -- 2. general edit: the coordinator can change answers only after the person allows it; history of choices kept
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_answer_save('dimension_housing', 'condition', '3', 'answered', null, a);
  execute 'reset role';
  select count(*) into n from mirror.consents where individual_id = a;
  perform set_config('role', 'authenticated', true);
  r := r || format('2 general edit allowed after consent; consent rows kept (2: health then general): %s', n = 2);

  -- 3. the person ends work with the organization: coordinator refused even for general; all sharing withdrawn
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_org_end(x);
  j := public.mirror_my_settings();
  ok := j -> 'organizations' -> 0 ->> 'status' = 'ended' and (j -> 'organizations' -> 0 -> 'sharing') = '{}'::jsonb;
  begin perform public.mirror_my_consent_set(x, 'health', 'view'); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_set_get('dimension_housing', a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('3 person ends the organization: everything withdrawn, coordinator refused: %s', ok);

  -- 4. profile, safety mode, export, deletion request and cancel
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_profile_save('{"preferred_name": "CHECK Pat", "birth_year": "1990"}');
  perform public.mirror_my_safety(true);
  j := public.mirror_my_export();
  ok := j -> 'me' ->> 'preferred_name' = 'CHECK Pat' and (j -> 'me' ->> 'safety_mode')::boolean
    and jsonb_array_length(j -> 'answers') >= 2 and jsonb_array_length(j -> 'sharing_history') = 2 and jsonb_array_length(j -> 'who_looked') >= 1;
  j := public.mirror_my_deletion(true);
  ok := ok and j ->> 'deletion_requested_at' is not null and (j ->> 'deletion_on')::date = current_date + 30;
  j := public.mirror_my_deletion(false);
  ok := ok and j ->> 'deletion_requested_at' is null;
  begin perform public.mirror_my_profile_save('{"preferred_name": " "}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('4 name, safety mode, export (answers, history, who looked), deletion request + cancel: %s', ok);

  -- 5. another person sees only their own; a coordinator with no Mirror of their own gets nothing; changes are audited
  perform set_config('request.jwt.claims', pb, true);
  j := public.mirror_my_settings();
  ok := j -> 'person' ->> 'preferred_name' = 'CHECK PB' and jsonb_array_length(j -> 'organizations') = 0;
  begin perform public.mirror_my_consent_set(x, 'health', 'view'); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_my_settings(); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and actor_role = 'self' and action in ('consent_grant', 'consent_revoke', 'org_end', 'export', 'delete_request', 'delete_cancel', 'safety_on');
  r := r || format('5 others see only their own, coordinator without a Mirror refused; person''s changes audited (%s of 8): %s', n, ok and n = 8);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
