-- Phase N TN.1 check: sharing beyond housing for Navigator people. Fictional Navigators and people (marked sample, so nothing is ever
-- emailed); always rolled back.
do $chk$
declare
  r text[] := '{}'; n1 uuid; n2 uuid; p uuid; q uuid; ind uuid; org uuid; j jsonb; ok boolean; k int;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); j1 text; j2 text;
begin
  insert into auth.users (id, email) values (u1, 'check.na@example.invalid'), (u2, 'check.nb@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (s1, u1, now(), now(), now(), 'aal1'), (s2, u2, now(), now(), now(), 'aal1');
  j1 := json_build_object('sub', u1, 'email', 'check.na@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s1)::text;
  j2 := json_build_object('sub', u2, 'email', 'check.nb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s2)::text;
  insert into navigators (name, email, status, business_name) values ('CHECK Navigator A', 'check.na@example.invalid', 'pilot', 'CHECK Care LLC') returning id into n1;
  insert into navigators (name, email, status) values ('CHECK Navigator B', 'check.nb@example.invalid', 'pilot') returning id into n2;
  insert into nav_referrals (navigator_id, first_name, last_name, is_sample, consent_name, consent_on, consent_version, status)
    values (n1, 'Check', 'Person', true, 'Check Person', current_date, 'nav-consent-2026-11', 'searching') returning id into p;
  insert into nav_referrals (navigator_id, first_name, last_name, is_sample, status) values (n1, 'Check', 'Unsigned', true, 'draft') returning id into q;
  perform set_config('role', 'authenticated', true);

  -- 1. the Navigator sees the 7 topics, may record (housing consent signed), nothing recorded yet; housing consent words unchanged
  perform set_config('request.jwt.claims', j1, true);
  j := public.nav_whole_consent(p);
  ok := jsonb_array_length(j -> 'topics') = 7 and (j ->> 'can_record')::boolean and j -> 'current' = 'null'::jsonb
    and j ->> 'receiver' = 'my Housing Navigator, CHECK Navigator A (CHECK Care LLC)'
    and public.nav_consent_text() like '%only to help me find and keep a home%'
    and not (public.nav_whole_consent(q) ->> 'can_record')::boolean;
  r := r || format('1 seven topics, recordable only after the housing consent; housing consent text unchanged: %s', ok);

  -- 2. wrong name or a bad choice refused; the right name saves the exact words and logs it
  ok := true;
  begin perform public.nav_whole_consent_save(p, '{"health":"view"}', 'Someone Else'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.nav_whole_consent_save(p, '{"health":"all"}', 'Check Person'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.nav_whole_consent_save(q, '{"health":"view"}', 'Check Unsigned'); ok := false; exception when others then null; end;
  j := public.nav_whole_consent_save(p, '{"health":"view","financial":"edit","documents":"view"}', '  check   person ');
  ok := ok and j -> 'current' -> 'topics' ->> 'health' = 'view' and j -> 'current' -> 'topics' ->> 'mental_health' = 'none'
    and j -> 'current' ->> 'words' like 'Beyond housing, I agree that my Housing Navigator, CHECK Navigator A (CHECK Care LLC) may work with me on my Human Mirror and see my physical health (see), my money and my Daily Number (see and change), my documents (see).%'
    and j -> 'current' ->> 'words' like '%Everything else private stays private: how I feel inside, my safety,%';
  execute 'reset role';
  ok := ok and exists (select 1 from nav_events where referral_id = p and action = 'whole_consent' and detail like 'Sharing beyond housing signed by%');
  r := r || format('2 typed full name required; exact words kept; logged: %s', ok);

  -- 3. another Navigator cannot see or record; a new signing replaces the old one (both kept)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j2, true);
  ok := true;
  begin perform public.nav_whole_consent(p); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.nav_whole_consent_save(p, '{}', 'Check Person'); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_whole_consent_save(p, '{"health":"edit","financial":"view"}', 'Check Person');
  execute 'reset role';
  ok := ok and (select count(*) from nav_whole_consents where nav_referral_id = p) = 2
    and (select count(*) from nav_whole_consents where nav_referral_id = p and replaced_at is null) = 1;
  r := r || format('3 other Navigator refused; re-signing replaces, history kept: %s', ok);

  -- 4. TN.2 hand-off: copied into mirror.consents for the Navigator's own organization, and re-copying follows the latest choice
  insert into mirror.organizations (name, kind, navigator_id) values ('CHECK Care LLC', 'navigator', n1) returning id into org;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.np@example.invalid', 'CHECK NP') returning id into ind;
  k := mirror.nav_whole_consent_to_mirror(p, ind);
  ok := k = 2 and exists (select 1 from mirror.consents where individual_id = ind and organization_id = org and category = 'health' and access = 'edit' and revoked_at is null)
    and exists (select 1 from mirror.consents where individual_id = ind and organization_id = org and category = 'financial' and access = 'view' and revoked_at is null)
    and not exists (select 1 from mirror.consents where individual_id = ind and category = 'documents' and revoked_at is null);
  r := r || format('4 copied into the Mirror for the Navigator''s organization (%s topics): %s', k, ok);

  -- 5. withdrawing the housing consent ends sharing beyond housing; nothing more is copied
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_referral_withdraw_consent(p);
  execute 'reset role';
  ok := (select withdrawn_on is not null from nav_whole_consents where nav_referral_id = p and replaced_at is null)
    and mirror.nav_whole_consent_to_mirror(p, ind) = 0;
  r := r || format('5 withdrawing the housing consent ends it: %s', ok);

  -- 6. closed to browsers
  ok := not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'public' and g.table_name = 'nav_whole_consents'
                    and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
    and not has_function_privilege('anon', 'public.nav_whole_consent_save(uuid, jsonb, text)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.nav_whole_consent_to_mirror(uuid, uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.nav_whole_consent(uuid)', 'execute');
  r := r || format('6 table and Mirror copy closed to browsers: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
