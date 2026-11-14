-- Mirror T6.2 check: strengths inventory and suggestions from answers. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; s1 uuid; s2 uuid; k text; n int; ok boolean;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid();
  pa text; pb text; cx text; c1 text;
begin
  -- fictional sign-in rows (fix 5 treats a session id that does not exist as signed out)
  insert into auth.users (id, email) values (ua, 'check.sa@example.invalid'), (ub, 'check.sb@example.invalid'), (uc, 'check.scx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now()), (sc1, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.sa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.sb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.scx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.scx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.sa@example.invalid', 'CHECK SA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.sb@example.invalid', 'CHECK SB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.scx@example.invalid', 'CHECK SCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the person adds an everyday strength and a private one (health area); sees both, grouped by kind; bad input refused
  perform set_config('request.jwt.claims', pa, true);
  s1 := (public.mirror_strength_save(null, 'skill', 'Forklift driving', 'Certified 2019', null) ->> 'id')::uuid;
  s2 := (public.mirror_strength_save(null, 'experience', 'Got sober and stayed sober', null, 'physical_health') ->> 'id')::uuid;
  j := public.mirror_strengths();
  ok := (j ->> 'self')::boolean and jsonb_array_length(j -> 'strengths') = 2 and not (j ? 'hidden') and jsonb_array_length(j -> 'can_add') = 6
    and j -> 'strengths' -> 0 ->> 'kind' = 'skill' and (j -> 'strengths' -> 1 ->> 'private')::boolean;
  begin perform public.mirror_strength_save(null, 'skill', '  '); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_strength_save(null, 'superpower', 'Flying'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_strength_save(null, 'skill', 'x', null, 'no_such_area'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_strength_save(null, 'skill', repeat('x', 121)); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('1 person adds 2 strengths (skills first, health one marked private), may add in all 6 topics, bad input refused: %s', ok);

  -- 2. suggestions from answers: chosen skills by label, languages split, schooling credential, written answers split; not "some college"
  perform public.mirror_answer_save('reflection_assets', 'can_do', '["cooking","repairs","languages"]');
  perform public.mirror_answer_save('reflection_assets', 'languages', '"English, Spanish and Hmong"');
  perform public.mirror_answer_save('reflection_assets', 'good_at', '"Listening to people; calming kids down"');
  perform public.mirror_answer_save('reflection_history', 'schooling', '"certificate"');
  perform public.mirror_answer_save('reflection_history', 'people', '"My aunt Rosa"');
  j := public.mirror_strength_suggestions();
  ok := jsonb_array_length(j) = 9
    and (select count(*) from jsonb_array_elements(j) e where e ->> 'kind' = 'skill') = 2
    and (select count(*) from jsonb_array_elements(j) e where e ->> 'kind' = 'language') = 3
    and (select count(*) from jsonb_array_elements(j) e where e ->> 'kind' = 'talent') = 2
    and exists (select 1 from jsonb_array_elements(j) e where e ->> 'kind' = 'credential' and e ->> 'title' = 'A trade certificate or license')
    and exists (select 1 from jsonb_array_elements(j) e where e ->> 'kind' = 'relationship' and e ->> 'title' = 'My aunt Rosa')
    and not exists (select 1 from jsonb_array_elements(j) e where e ->> 'title' ilike '%more than one language%');
  r := r || format('2 suggestions: 2 skills, 3 languages, 2 talents, 1 credential, 1 relationship (9): %s (%s)', ok, jsonb_array_length(j));

  -- 3. saving a suggestion removes it; "not a strength" hides one for good; a made-up suggestion key is refused; a repeat save refused
  k := (select e ->> 'source_key' from jsonb_array_elements(j) e where e ->> 'title' = 'Cooking');
  perform public.mirror_strength_save(null, 'skill', 'Cooking for a crowd', null, null, k);
  perform public.mirror_strength_dismiss((select e ->> 'source_key' from jsonb_array_elements(j) e where e ->> 'title' = 'Hmong'));
  j := public.mirror_strength_suggestions();
  ok := jsonb_array_length(j) = 7 and not exists (select 1 from jsonb_array_elements(j) e where e ->> 'title' in ('Cooking', 'Hmong'));
  begin perform public.mirror_strength_save(null, 'skill', 'Cooking', null, null, k); ok := ok and false; exception when unique_violation then null; end;
  begin perform public.mirror_strength_save(null, 'skill', 'Fake', null, null, 'reflection_assets:can_do:nope'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_strength_dismiss('reflection_assets:can_do:nope'); ok := ok and false; exception when invalid_parameter_value then null; end;
  -- a strength typed by hand with the same title as a suggestion also removes that suggestion
  perform public.mirror_strength_save(null, 'relationship', 'my aunt rosa');
  ok := ok and jsonb_array_length(public.mirror_strength_suggestions()) = 6;
  r := r || format('3 saved suggestion leaves the list, dismissed one hidden, repeats and made-up keys refused, same title by hand counts: %s', ok);

  -- 4. coordinator without edit sharing: sees everyday strengths only (private one hidden), no suggestions, cannot add, change or remove
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_strengths(a);
  ok := not (j ->> 'self')::boolean and jsonb_array_length(j -> 'strengths') = 3 and not (j ? 'hidden') and jsonb_array_length(j -> 'can_add') = 0
    and jsonb_array_length(public.mirror_strength_suggestions(a)) = 0;
  begin perform public.mirror_strength_save(null, 'skill', 'Bus driving', null, null, null, a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_strength_save(s1, 'skill', 'Changed', null, null); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_strength_delete(s1); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_strength_delete(s2); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator (view only) sees 3, no hidden count (D-29), no suggestions, cannot add, change or remove: %s', ok);

  -- 5. with the person's "see and change": coordinator adds one (marked coordinator), sees suggestions, edits; still no private one;
  --    without the authenticator nothing; another person sees nothing of A's list
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_strength_save(null, 'credential', 'CNA license', null, null, null, a);
  ok := j ->> 'source' = 'coordinator' and jsonb_array_length(public.mirror_strength_suggestions(a)) = 6;
  ok := ok and (public.mirror_strength_save(s1, 'skill', 'Forklift and pallet jack', 'Certified 2019', null) ->> 'title') = 'Forklift and pallet jack';
  begin perform public.mirror_strength_save(s1, 'skill', 'x', null, 'mental_health'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_strength_delete(s2); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_strengths(a); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pb, true);
  j := public.mirror_strengths();
  ok := ok and jsonb_array_length(j -> 'strengths') = 0 and jsonb_array_length(public.mirror_strength_suggestions()) = 0;
  begin perform public.mirror_strength_delete(s1); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_strengths(a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('5 with edit sharing: coordinator adds and edits everyday only; no authenticator = refused; person B sees nothing of A: %s', ok);

  -- 6. person removes one, downloads the rest; browsers cannot reach the tables or helpers; anon cannot call
  perform set_config('request.jwt.claims', pa, true);
  ok := public.mirror_strength_delete(s2);
  j := public.mirror_my_export_strengths();
  ok := ok and jsonb_array_length(j) = 4 and exists (select 1 from jsonb_array_elements(j) e where e ->> 'added_by' = 'coordinator');
  execute 'reset role';
  ok := ok and not has_table_privilege('authenticated', 'mirror.strengths', 'select') and not has_table_privilege('anon', 'mirror.strength_dismissals', 'select')
     and not has_function_privilege('anon', 'public.mirror_strengths(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'mirror.strength_candidates(uuid)', 'execute');
  select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'strengths';
  r := r || format('6 person removes the private one, downloads 4; tables and helpers closed to browsers; %s audit rows on strengths: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
