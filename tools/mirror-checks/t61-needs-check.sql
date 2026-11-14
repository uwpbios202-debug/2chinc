-- Mirror T6.1 check: needs inventory and life cycle. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; h uuid; p uuid; n int; ok boolean;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid();
  pa text; pb text; cx text; c1 text;
begin
  -- fictional sign-in rows (Phase 2 fix 5 treats a session id that does not exist as signed out)
  insert into auth.users (id, email) values (ua, 'check.na@example.invalid'), (ub, 'check.nb@example.invalid'), (uc, 'check.ncx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now()), (sc1, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.na@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.nb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.ncx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.ncx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.na@example.invalid', 'CHECK NA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.nb@example.invalid', 'CHECK NB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.ncx@example.invalid', 'CHECK NCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the person adds an everyday need and a private one; sees both; may add in every topic; bad input refused in plain words
  perform set_config('request.jwt.claims', pa, true);
  h := (public.mirror_need_save(null, 'housing', 'A place of my own', 'Studio is fine', 'urgent') ->> 'id')::uuid;
  p := (public.mirror_need_save(null, 'physical_health', 'Dentist', null, 'soon') ->> 'id')::uuid;
  j := public.mirror_needs_list();
  ok := (j ->> 'self')::boolean and jsonb_array_length(j -> 'needs') = 2 and not (j ? 'hidden') and jsonb_array_length(j -> 'can_add') = 6
    and j -> 'needs' -> 0 ->> 'title' = 'A place of my own';
  begin perform public.mirror_need_save(null, 'housing', '   '); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_need_save(null, 'no_such_area', 'x'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_need_save(null, 'housing', 'x', null, 'someday'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('1 person adds 2 needs, sees both (urgent first), may add in all 6 topics, bad input refused: %s', ok);

  -- 2. coordinator: sees the everyday need only (no hint that a private one exists: no hidden count, D-29); may not add or change without the person's edit OK
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_needs_list(a);
  ok := not (j ->> 'self')::boolean and jsonb_array_length(j -> 'needs') = 1 and not (j ? 'hidden') and jsonb_array_length(j -> 'can_add') = 0;
  begin perform public.mirror_need_save(null, 'housing', 'Bus pass', null, 'soon', a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_need_status(h, 'planning'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_need_history(p); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('2 coordinator sees 1, no hidden count, cannot add, move or read the private history without consent: %s', ok);

  -- 3. life cycle: person moves it on; person cannot verify; coordinator with edit OK verifies only from obtained; history exact
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_need_status(h, 'planning', 'Looking at listings');
  perform public.mirror_need_status(h, 'obtained', 'Signed a lease');
  begin perform public.mirror_need_status(h, 'verified'); ok := false; exception when insufficient_privilege then ok := true; end;
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_need_status(h, 'verified', 'Saw the lease');
  ok := ok and j ->> 'status' = 'verified' and j ->> 'verified_at' is not null;
  begin perform public.mirror_need_status(h, 'verified'); exception when others then ok := false; end;   -- same status: no change, no error
  j := public.mirror_need_history(h);
  ok := ok and jsonb_array_length(j) = 4
    and j -> 0 ->> 'from' = 'obtained' and j -> 0 ->> 'to' = 'verified' and j -> 0 ->> 'by_role' = 'coordinator'
    and j -> 3 ->> 'from' is null and j -> 3 ->> 'to' = 'identified';
  -- the person reopens it: verified_at cleared
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_need_status(h, 'in_progress', 'Lease fell through');
  ok := ok and j ->> 'verified_at' is null;
  begin perform public.mirror_need_status(p, 'verified'); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('3 identified > planning > obtained > verified (coordinator only, from obtained), 4 history rows, reopen clears verified: %s', ok);

  -- 4. the coordinator needs the authenticator; another person sees nothing of A's needs
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_needs_list(a); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pb, true);
  ok := ok and jsonb_array_length(public.mirror_needs_list() -> 'needs') = 0;
  begin perform public.mirror_needs_list(a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_need_status(h, 'planning'); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator without authenticator refused; another person sees none of A''s needs and cannot change them: %s', ok);

  -- 5. sharing health lets the coordinator see the private need, and that look is logged; export has both needs with history
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'health', 'view');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_needs_list(a);
  ok := jsonb_array_length(j -> 'needs') = 2 and not (j ? 'hidden');
  r := r || format('5a shared health -> coordinator sees both needs (%s), no hidden count: %s',
    jsonb_array_length(j -> 'needs'), ok);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_needs();
  -- find each need by its words (both were added in the same instant here, so their order is not fixed)
  ok := jsonb_array_length(j) = 2
    and (select jsonb_array_length(e -> 'history') from jsonb_array_elements(j) e where e ->> 'need' = 'A place of my own') = 5
    and (select jsonb_array_length(e -> 'history') from jsonb_array_elements(j) e where e ->> 'need' = 'Dentist') = 1;
  r := r || format('5b export has 2 needs; history 5 for the housing need, 1 for the dentist: %s', ok);
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and actor_role = 'coordinator' and action = 'view' and category = 'health' and table_name = 'needs';
  r := r || format('5c the coordinator''s look at the private need is logged (%s rows): %s', n, n >= 1);

  -- 6. no deleting one by one, history never changed, no bulk emptying; the whole Mirror still deletes cleanly
  ok := true;
  begin delete from mirror.needs where id = p; ok := false; exception when insufficient_privilege then null; end;
  begin update mirror.need_events set note = 'changed' where need_id = h; ok := false; exception when insufficient_privilege then null; end;
  begin delete from mirror.need_events where need_id = h; ok := false; exception when insufficient_privilege then null; end;
  begin truncate mirror.need_events; ok := false; exception when insufficient_privilege then null; end;
  delete from mirror.individuals where id = a;
  ok := ok and not exists (select 1 from mirror.needs where id in (h, p)) and not exists (select 1 from mirror.need_events where need_id in (h, p));
  r := r || format('6 no single delete, history fixed, no truncate; deleting the whole Mirror removes needs and history: %s', ok);

  -- 7. a browser cannot reach the tables
  ok := not has_table_privilege('authenticated', 'mirror.needs', 'select') and not has_table_privilege('anon', 'mirror.need_events', 'select')
    and not has_table_privilege('service_role', 'mirror.needs', 'truncate');
  r := r || format('7 tables closed to browsers; no TRUNCATE for service_role: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
