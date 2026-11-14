-- Mirror P2-12 check: end dates for sharing, kept through changes, shown to both sides, a reminder 7 days before, and the share stops after.
-- Fictional organization and people; always rolled back (no email is sent).
do $chk$
declare
  r text[] := '{}'; o uuid; a uuid; b uuid; s uuid; j jsonb; ok boolean; d date := (now() at time zone 'America/Chicago')::date;
  up uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); us uuid := gen_random_uuid();
  sp uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); ss uuid := gen_random_uuid(); jp text; jc text; js text;
begin
  insert into auth.users (id, email) values (up, 'check.xp@example.invalid'), (uc, 'check.xc@example.invalid'), (us, 'check.xs@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values
    (sp, up, now(), now(), now(), 'aal1'), (sc, uc, now(), now(), now(), 'aal2'), (ss, us, now(), now(), now(), 'aal1');
  jp := json_build_object('sub', up, 'email', 'check.xp@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sp)::text;
  jc := json_build_object('sub', uc, 'email', 'check.xc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  js := json_build_object('sub', us, 'email', 'check.xs@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', ss)::text;
  insert into mirror.organizations (name, kind) values ('CHECK Share Org', 'nonprofit') returning id into o;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.xc@example.invalid', 'CHECK XC', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name) values ('check.xp@example.invalid', 'Pat') returning id into a;
  insert into mirror.individuals (preferred_name) values ('No Sign-in') returning id into b;
  insert into mirror.individuals (auth_email, preferred_name, safety_sensitive) values ('check.xs@example.invalid', 'Sky', true) returning id into s;
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (o, a, 'active'), (o, b, 'active'), (o, s, 'active');

  -- 1. the person sets an end date; wrong dates refused; changing how much is shared keeps it; clearing works
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jp, true);
  perform public.mirror_my_consent_set(o, 'health', 'view');
  perform public.mirror_my_consent_until(o, 'health', d + 10);
  ok := true;
  begin perform public.mirror_my_consent_until(o, 'health', d); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_my_consent_until(o, 'health', d + 2000); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_my_consent_until(o, 'legal', d + 5); ok := false; exception when invalid_parameter_value then null; end;
  perform public.mirror_my_consent_set(o, 'health', 'edit');
  j := public.mirror_my_settings();
  ok := ok and (select (e -> 'sharing_until' ->> 'health')::date = d + 10 and e -> 'sharing' ->> 'health' = 'edit' from jsonb_array_elements(j -> 'organizations') e where (e ->> 'id')::uuid = o);
  perform public.mirror_my_consent_until(o, 'health', null);
  j := public.mirror_my_settings();
  ok := ok and (select not (e -> 'sharing_until') ? 'health' from jsonb_array_elements(j -> 'organizations') e where (e ->> 'id')::uuid = o);
  perform public.mirror_my_consent_until(o, 'health', d + 7);
  r := r || format('1 person sets, keeps through a change, and clears an end date; wrong dates refused: %s', ok);

  -- 2. the coordinator records an end date for a person without a sign-in, and sees it; not for someone who can sign in
  perform set_config('request.jwt.claims', jc, true);
  perform public.mirror_consent_record(b, o, 'financial', 'view', 'paper', 'Signed form in the paper file');
  j := public.mirror_consent_record_until(b, o, 'financial', d + 30);
  ok := (j -> 'sharing' -> 'financial' ->> 'until')::date = d + 30
    and (public.mirror_consents_recorded(a, o) -> 'sharing' -> 'health' ->> 'until')::date = d + 7;
  begin perform public.mirror_consent_record_until(a, o, 'health', d + 30); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('2 coordinator records and sees end dates; never for someone who can sign in: %s', ok);

  -- 3. 7 days before: held while the kind is off; when on, the words name the organization and date (safety mode: neutral)
  execute 'reset role';
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by, expires_on) values (s, o, 'documents', 'view', 'check.xs@example.invalid', d + 7);
  update portal_settings set value = '' where key = 'mirror_email_kinds_enabled';
  j := mirror.send_reminders();
  ok := exists (select 1 from mirror.notifications where individual_id = a and kind = 'mirror_sharing' and status = 'held');
  update portal_settings set value = 'mirror_sharing' where key = 'mirror_email_kinds_enabled';
  delete from mirror.notifications where individual_id in (a, s) and kind = 'mirror_sharing';
  j := mirror.send_reminders();
  ok := ok and (j ->> 'queued')::int >= 2
    and exists (select 1 from public.email_outbox where to_email = 'check.xp@example.invalid' and subject like 'What you share with CHECK Share Org ends on %')
    and exists (select 1 from public.email_outbox where to_email = 'check.xs@example.invalid' and subject = '2nd Chance Housing: a choice you made ends soon'
                and html !~* 'mirror|CHECK Share');
  r := r || format('3 a week before: held while off; when on, named for the person, neutral in safety mode: %s', ok);

  -- 4. after the end date the coordinator no longer sees it
  update mirror.consents set expires_on = d - 1 where individual_id = a and organization_id = o and category = 'health' and revoked_at is null;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  ok := not (public.mirror_consents_recorded(a, o) -> 'sharing') ? 'health';
  execute 'reset role';
  ok := ok and not mirror.may(a, 'health', 'view');
  r := r || format('4 after the end date the share stops: %s', ok);

  -- 5. closed to anon
  ok := not has_function_privilege('anon', 'public.mirror_my_consent_until(uuid, text, date)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_consent_record_until(uuid, uuid, text, date)', 'execute')
    and (select count(*) from jsonb_array_elements(mirror.email_kinds())) = 7;
  r := r || format('5 closed to anon; 7 email kinds: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
