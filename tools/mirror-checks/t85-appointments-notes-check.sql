-- Mirror T8.5 check: appointments and contact notes (D-35). Coordinators add for their own organization only with "see and change"
-- for the topic; the person sees all of theirs, keeps their own appointments to themselves, may say "I can't make it"; the dashboard
-- lists the coming week; notes never change (corrections are new notes); the person sees every note; no hidden counts; another
-- organization sees nothing. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t85-appointments-notes-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; j jsonb; e jsonb; n int; ok boolean; ap uuid; aw uuid; nt uuid;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; cx text; cy text;
begin
  insert into auth.users (id, email) values (ua, 'check.pa@example.invalid'), (uc, 'check.pcx@example.invalid'), (uy, 'check.pcy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
  values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now()), (sy, uy, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.pa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.pcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  cy := json_build_object('sub', uy, 'email', 'check.pcy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK PY', 'nonprofit') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.pa@example.invalid', 'CHECK PA', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.pcx@example.invalid', 'CHECK PCX', 'coordinator'), (y, 'check.pcy@example.invalid', 'CHECK PCY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. everyday "see and change": the coordinator adds one in an hour and one in 10 days; the person adds their own (court);
  --    the person sees all 3, the coordinator only the organization's 2
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform public.mirror_appointment_save(jsonb_build_object('title', 'CHECK court date', 'starts_at', now() + interval '2 days', 'dimension_key', 'housing'));
  perform set_config('request.jwt.claims', cx, true);
  ap := (public.mirror_appointment_save(jsonb_build_object('individual_id', a, 'organization_id', x, 'title', 'CHECK housing search',
          'starts_at', now() + interval '1 hour', 'place', 'Office')) ->> 'id')::uuid;
  perform public.mirror_appointment_save(jsonb_build_object('individual_id', a, 'organization_id', x, 'title', 'CHECK later', 'starts_at', now() + interval '10 days'));
  ok := jsonb_array_length(public.mirror_appointments(a, x) -> 'appointments') = 2;
  perform set_config('request.jwt.claims', pa, true);
  ok := ok and jsonb_array_length(public.mirror_appointments() -> 'appointments') = 3;
  r := r || format('1 coordinator adds for the organization; the person sees 3, the organization 2 (not the person''s own): %s', ok);

  -- 2. a health appointment is refused until health is shared "see and change"; the dashboard shows only the coming week's one
  perform set_config('request.jwt.claims', cx, true);
  ok := true;
  begin perform public.mirror_appointment_save(jsonb_build_object('individual_id', a, 'organization_id', x, 'title', 'CHECK clinic',
    'starts_at', now() + interval '3 hours', 'dimension_key', 'physical_health')); ok := false; exception when others then null; end;
  j := public.mirror_workspace_appointments(x);
  ok := ok and jsonb_array_length(j -> 'appointments') = 1 and j -> 'appointments' -> 0 ->> 'id' = ap::text;
  r := r || format('2 private appointment refused without the topic; dashboard lists only this week''s: %s', ok);

  -- 3. the person says "I can't make it" (history by them); they cannot move the time; the coordinator sets a new time
  perform set_config('request.jwt.claims', pa, true);
  e := public.mirror_appointment_save(jsonb_build_object('id', ap, 'status', 'cancelled', 'note', 'CHECK sick'));
  ok := e ->> 'status' = 'cancelled' and e -> 'history' -> 1 ->> 'by_role' = 'self';
  begin perform public.mirror_appointment_save(jsonb_build_object('id', ap, 'status', 'scheduled', 'starts_at', now() + interval '1 day')); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', cx, true);
  e := public.mirror_appointment_save(jsonb_build_object('id', ap, 'status', 'scheduled', 'starts_at', now() + interval '1 day', 'note', 'New day'));
  ok := ok and e ->> 'status' = 'scheduled' and jsonb_array_length(e -> 'history') = 3 and e -> 'history' -> 2 ->> 'by_role' = 'coordinator';
  r := r || format('3 the person can say they can''t make it, not move it; the coordinator sets a new time; 3 history lines: %s', ok);

  -- 4. notes: an everyday note; a health note refused, then allowed once shared; the person sees both with the writer's name;
  --    health taken back: the organization sees 1; the health look was logged
  nt := (public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', x, 'kind', 'call', 'summary', 'CHECK called about the lease')) ->> 'id')::uuid;
  ok := nt is not null;
  begin perform public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', x, 'category', 'health', 'kind', 'visit', 'summary', 'CHECK x')); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'health', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', x, 'category', 'health', 'kind', 'visit', 'summary', 'CHECK went to the clinic together'));
  ok := ok and jsonb_array_length(public.mirror_interactions(a, x) -> 'notes') = 2;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_interactions();
  ok := ok and jsonb_array_length(j -> 'notes') = 2 and j -> 'notes' -> 0 ->> 'by' = 'CHECK PCX';
  perform public.mirror_my_consent_set(x, 'health', 'none');
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and jsonb_array_length(public.mirror_interactions(a, x) -> 'notes') = 1;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs l where l.individual_id = a and l.table_name = 'interactions' and l.category = 'health';
  perform set_config('role', 'authenticated', true);
  ok := ok and n >= 1;
  r := r || format('4 notes: private one only with the topic; the person sees all with the writer; taken back: 1 left; look logged (%s): %s', n, ok);

  -- 5. notes never change: a direct change is refused; a correction is a new linked note and marks the first as corrected
  execute 'reset role';
  ok := true;
  begin update mirror.interactions set summary = 'changed' where id = nt; ok := false; exception when others then null; end;
  begin delete from mirror.interactions where id = nt; ok := false; exception when others then null; end;
  perform set_config('role', 'authenticated', true);
  perform public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', x, 'corrects', nt, 'summary', 'CHECK it was about the deposit'));
  select v into e from jsonb_array_elements(public.mirror_interactions(a, x) -> 'notes') v where v ->> 'id' = nt::text;
  ok := ok and (e ->> 'corrected')::boolean and jsonb_array_length(public.mirror_interactions(a, x) -> 'notes') = 2;
  r := r || format('5 a note cannot be changed or deleted; a correction is a new linked note: %s', ok);

  -- 6. another organization sees and adds nothing; the person downloads 3 appointments and 3 notes
  perform set_config('request.jwt.claims', cy, true);
  ok := true;
  begin perform public.mirror_appointments(a, y); ok := false; exception when others then null; end;
  begin perform public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', y, 'summary', 'CHECK y')); ok := false; exception when others then null; end;
  begin perform public.mirror_appointment_save(jsonb_build_object('id', ap, 'status', 'done')); ok := false; exception when others then null; end;
  ok := ok and jsonb_array_length(public.mirror_workspace_appointments(y) -> 'appointments') = 0;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_appointments();
  ok := ok and jsonb_array_length(j -> 'appointments') = 3 and jsonb_array_length(j -> 'notes_about_me') = 3;
  r := r || format('6 another organization refused; the person downloads 3 appointments and 3 notes: %s', ok);

  -- 7. deleting the whole Mirror (D-18) still removes the appointments and the notes
  execute 'reset role';
  delete from mirror.individuals where id = a;
  ok := not exists (select 1 from mirror.interactions where individual_id = a) and not exists (select 1 from mirror.appointments where individual_id = a);
  r := r || format('7 deleting the whole Mirror removes its appointments and notes: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
