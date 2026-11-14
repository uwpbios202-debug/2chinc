-- Mirror T8.4 check: services and enrollments (D-34). Organization admins keep the list; coordinators enroll only with the person's
-- "see and change" for the service's topic; the person sees all of theirs and may say they stopped; each change is in the history;
-- no hidden counts; another organization sees nothing. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t84-services-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; j jsonb; e jsonb; n int; ok boolean; sf uuid; sm uuid; ef uuid; em uuid;
  ua uuid := gen_random_uuid(); uo uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); so uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; ox text; cx text; cy text;
begin
  insert into auth.users (id, email) values (ua, 'check.sa@example.invalid'), (uo, 'check.sox@example.invalid'),
    (uc, 'check.scx@example.invalid'), (uy, 'check.scy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
  values (sa, ua, now(), now(), now()), (so, uo, now(), now(), now()), (sc, uc, now(), now(), now()), (sy, uy, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.sa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  ox := json_build_object('sub', uo, 'email', 'check.sox@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', so)::text;
  cx := json_build_object('sub', uc, 'email', 'check.scx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  cy := json_build_object('sub', uy, 'email', 'check.scy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK SY', 'nonprofit') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.sa@example.invalid', 'CHECK SA', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.sox@example.invalid', 'CHECK SOX', 'org_admin'), (x, 'check.scx@example.invalid', 'CHECK SCX', 'coordinator'),
    (y, 'check.scy@example.invalid', 'CHECK SCY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the admin adds two services (everyday food; private mental health); a coordinator cannot; a second "Food pantry" is refused
  perform set_config('request.jwt.claims', ox, true);
  sf := (public.mirror_service_save(jsonb_build_object('organization_id', x, 'name', 'CHECK Food pantry', 'dimension_key', 'food')) ->> 'id')::uuid;
  sm := (public.mirror_service_save(jsonb_build_object('organization_id', x, 'name', 'CHECK Counseling', 'dimension_key', 'mental_health')) ->> 'id')::uuid;
  ok := sf is not null and sm is not null;
  begin perform public.mirror_service_save(jsonb_build_object('organization_id', x, 'name', 'check food PANTRY ')); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_service_save(jsonb_build_object('organization_id', x, 'name', 'CHECK Rides')); ok := false; exception when others then null; end;
  ok := ok and not (public.mirror_services(x) ->> 'can_manage')::boolean
    and (select (v ->> 'private')::boolean from jsonb_array_elements(public.mirror_services(x) -> 'services') v where v ->> 'id' = sm::text);
  r := r || format('1 admins keep the list (coordinator refused, same name refused, counseling private): %s', ok);

  -- 2. the person shares everyday topics "see and change": food enrollment works, twice refused, counseling refused and not offered
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  ef := (public.mirror_enrollment_save(jsonb_build_object('service_id', sf, 'individual_id', a, 'note', 'Weekly box')) ->> 'id')::uuid;
  ok := ef is not null;
  begin perform public.mirror_enrollment_save(jsonb_build_object('service_id', sf, 'individual_id', a)); ok := false; exception when others then null; end;
  begin perform public.mirror_enrollment_save(jsonb_build_object('service_id', sm, 'individual_id', a)); ok := false; exception when others then null; end;
  j := public.mirror_enrollments(a, x);
  ok := ok and jsonb_array_length(j -> 'enrollments') = 1 and jsonb_array_length(j -> 'services') = 0;
  r := r || format('2 enroll with everyday "see and change"; not twice; private service refused and not offered: %s', ok);

  -- 3. history: the coordinator puts it on hold; the person cannot mark it finished, but can say they stopped (end date set)
  perform public.mirror_enrollment_save(jsonb_build_object('id', ef, 'status', 'paused', 'note', 'Away for a month'));
  perform set_config('request.jwt.claims', pa, true);
  ok := true;
  begin perform public.mirror_enrollment_save(jsonb_build_object('id', ef, 'status', 'completed')); ok := false; exception when others then null; end;
  e := public.mirror_enrollment_save(jsonb_build_object('id', ef, 'status', 'ended', 'note', 'I moved'));
  ok := ok and e ->> 'status' = 'ended' and e ->> 'ended_on' is not null and jsonb_array_length(e -> 'history') = 3
    and e -> 'history' -> 1 ->> 'to' = 'paused' and e -> 'history' -> 1 ->> 'by_role' = 'coordinator'
    and e -> 'history' -> 2 ->> 'by_role' = 'self' and e -> 'history' -> 2 ->> 'note' = 'I moved';
  r := r || format('3 on hold by the coordinator, the person cannot mark finished but can say they stopped; 3 history lines: %s', ok);

  -- 4. private topic: shared "see and change" -> counseling enrollment counted; taken back -> not listed, not counted; look logged
  perform public.mirror_my_consent_set(x, 'mental_health', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  em := (public.mirror_enrollment_save(jsonb_build_object('service_id', sm, 'individual_id', a)) ->> 'id')::uuid;
  ok := (select (v ->> 'getting_it')::int from jsonb_array_elements(public.mirror_services(x) -> 'services') v where v ->> 'id' = sm::text) = 1
    and jsonb_array_length(public.mirror_enrollments(a, x) -> 'enrollments') = 2;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'mental_health', 'none');
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and (select (v ->> 'getting_it')::int from jsonb_array_elements(public.mirror_services(x) -> 'services') v where v ->> 'id' = sm::text) = 0
    and jsonb_array_length(public.mirror_enrollments(a, x) -> 'enrollments') = 1;
  begin perform public.mirror_enrollment_save(jsonb_build_object('id', em, 'status', 'paused')); ok := false; exception when others then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs l where l.individual_id = a and l.table_name = 'service_enrollments' and l.category = 'mental_health';
  perform set_config('role', 'authenticated', true);
  ok := ok and n >= 1;
  r := r || format('4 private service counted only while shared; taken back: not listed, not counted, not changeable; look logged (%s): %s', n, ok);

  -- 5. another organization sees nothing; the area stays once enrolled; a retired service takes no one new
  perform set_config('request.jwt.claims', cy, true);
  ok := true;
  begin perform public.mirror_enrollments(a, y); ok := false; exception when others then null; end;
  begin perform public.mirror_enrollment_save(jsonb_build_object('id', ef, 'status', 'active')); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', ox, true);
  begin perform public.mirror_service_save(jsonb_build_object('id', sf, 'name', 'CHECK Food pantry', 'dimension_key', 'housing')); ok := false; exception when others then null; end;
  perform public.mirror_service_save(jsonb_build_object('id', sf, 'name', 'CHECK Food pantry', 'dimension_key', 'food', 'active', false));
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_enrollment_save(jsonb_build_object('service_id', sf, 'individual_id', a)); ok := false; exception when others then null; end;
  r := r || format('5 another organization refused; area fixed once enrolled; retired service takes no one new: %s', ok);

  -- 6. the person sees both (also the private one they no longer share) and downloads both
  perform set_config('request.jwt.claims', pa, true);
  ok := jsonb_array_length(public.mirror_enrollments() -> 'enrollments') = 2 and jsonb_array_length(public.mirror_my_export_services()) = 2;
  r := r || format('6 the person sees and downloads all their enrollments: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
