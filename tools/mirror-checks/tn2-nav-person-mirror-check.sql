-- Phase N TN.2 check: a Navigator person gets a Human Mirror from their Navigator file. Fictional Navigators and people; always rolled
-- back (the office email on a withdrawal is only queued inside this transaction, so it vanishes with it).
do $chk$
declare
  r text[] := '{}'; n1 uuid; n2 uuid; p uuid; p2 uuid; p3 uuid; ps uuid; org uuid; ind uuid; ind2 uuid; old_ind uuid; j jsonb; ok boolean;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); j1 text; j2 text;
begin
  insert into auth.users (id, email) values (u1, 'check.ta@example.invalid'), (u2, 'check.tb@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (s1, u1, now(), now(), now(), 'aal1'), (s2, u2, now(), now(), now(), 'aal1');
  j1 := json_build_object('sub', u1, 'email', 'check.ta@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s1)::text;
  j2 := json_build_object('sub', u2, 'email', 'check.tb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s2)::text;
  insert into navigators (name, email, status, business_name) values ('CHECK Nav T', 'check.ta@example.invalid', 'pilot', 'CHECK T Care') returning id into n1;
  insert into navigators (name, email, status) values ('CHECK Nav U', 'check.tb@example.invalid', 'pilot') returning id into n2;
  insert into nav_referrals (navigator_id, first_name, last_name, email, consent_name, consent_on, consent_version, status)
    values (n1, 'Check', 'Tee', 'check.tee@example.invalid', 'Check Tee', current_date, 'nav-consent-2026-11', 'searching') returning id into p;
  insert into nav_referrals (navigator_id, first_name, last_name, email, consent_name, consent_on, consent_version, status)
    values (n1, 'Check', 'Mail', 'check.mail@example.invalid', 'Check Mail', current_date, 'nav-consent-2026-11', 'searching') returning id into p2;
  insert into nav_referrals (navigator_id, first_name, last_name, email, consent_name, consent_on, consent_version, status)
    values (n1, 'Check', 'Known', 'check.known@example.invalid', 'Check Known', current_date, 'nav-consent-2026-11', 'searching') returning id into p3;
  insert into nav_referrals (navigator_id, first_name, is_sample, consent_name, consent_on, status) values (n1, 'Sample', true, 'Sample', current_date, 'searching') returning id into ps;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.known@example.invalid', 'Known Already') returning id into old_ind;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_whole_consent_save(p, '{"health":"view"}', 'Check Tee');

  -- 1. refused: without the person's yes, for a sample person, by another Navigator
  ok := true;
  begin perform public.nav_mirror_start(p, false, false); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.nav_mirror_start(ps, false, true); ok := false; exception when others then ok := ok and sqlerrm like 'Sample people%'; end;
  perform set_config('request.jwt.claims', j2, true);
  begin perform public.nav_mirror_start(p, false, true); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('1 refused without the yes, for samples, by another Navigator: %s', ok);

  -- 2. without email: the Navigator's organization is created (Navigator its admin), the Mirror is active, sharing copied
  perform set_config('request.jwt.claims', j1, true);
  j := public.nav_mirror_start(p, false, true);
  execute 'reset role';
  select id into org from mirror.organizations where navigator_id = n1 and kind = 'navigator';
  select mirror_individual_id into ind from nav_referrals where id = p;
  ok := org is not null and (select name from mirror.organizations where id = org) = 'CHECK T Care'
    and exists (select 1 from mirror.organization_members where organization_id = org and auth_email = 'check.ta@example.invalid' and role = 'org_admin')
    and (select auth_email is null and preferred_name = 'Check' and legal_name = 'Check Tee' from mirror.individuals where id = ind)
    and (select status from mirror.organization_individuals where organization_id = org and individual_id = ind) = 'active'
    and exists (select 1 from mirror.consents where individual_id = ind and organization_id = org and category = 'health' and access = 'view' and revoked_at is null)
    and j -> 'mirror' ->> 'status' = 'active' and not (j ->> 'own_signin')::boolean and not (j ->> 'can_start_mirror')::boolean
    and exists (select 1 from nav_events where referral_id = p and action = 'mirror_started');
  r := r || format('2 without email: organization made, Mirror active, sharing copied, logged: %s', ok);

  -- 3. without a sign-in, a new signing on the Navigator screen updates the Mirror's sharing
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_whole_consent_save(p, '{"financial":"edit"}', 'Check Tee');
  execute 'reset role';
  ok := not exists (select 1 from mirror.consents where individual_id = ind and organization_id = org and category = 'health' and revoked_at is null)
    and exists (select 1 from mirror.consents where individual_id = ind and organization_id = org and category = 'financial' and access = 'edit' and revoked_at is null);
  r := r || format('3 re-signing (no sign-in yet) updates the Mirror''s sharing: %s', ok);

  -- 4. with email: an invitation, and then the person changes sharing themselves (D-36 h); an existing Mirror is linked, never copied over
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  j := public.nav_mirror_start(p2, true, true);
  ok := j -> 'mirror' ->> 'status' = 'invited' and (j ->> 'own_signin')::boolean and not (j ->> 'can_record')::boolean;
  begin perform public.nav_whole_consent_save(p2, '{"health":"view"}', 'Check Mail'); ok := false; exception when others then ok := ok and sqlerrm like 'They have their own Human Mirror sign-in%'; end;
  j := public.nav_mirror_start(p3, true, true);
  execute 'reset role';
  ok := ok and (select mirror_individual_id from nav_referrals where id = p3) = old_ind
    and (select preferred_name from mirror.individuals where id = old_ind) = 'Known Already'
    and (select status from mirror.organization_individuals where organization_id = org and individual_id = old_ind) = 'invited';
  r := r || format('4 with email: invitation; sharing then theirs to change; an existing Mirror linked, not overwritten: %s', ok);

  -- 5. withdrawing the housing consent revokes the Navigator organization's sharing and ends the work; the Mirror stays the person's
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_referral_withdraw_consent(p);
  execute 'reset role';
  ok := not exists (select 1 from mirror.consents where individual_id = ind and organization_id = org and revoked_at is null)
    and (select status from mirror.organization_individuals where organization_id = org and individual_id = ind) = 'ended'
    and exists (select 1 from mirror.individuals where id = ind);
  r := r || format('5 housing consent withdrawn: sharing revoked, work ended, Mirror kept: %s', ok);

  -- 6. closed to browsers; already started cannot start twice
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  ok := true;
  begin perform public.nav_mirror_start(p2, true, true); ok := false; exception when others then ok := sqlerrm like 'Their Human Mirror is already started%'; end;
  execute 'reset role';
  ok := ok and not has_function_privilege('anon', 'public.nav_mirror_start(uuid, boolean, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.navigator_org(uuid, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.nav_mirror_state(public.nav_referrals)', 'execute');
  r := r || format('6 cannot start twice; helpers closed to browsers: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
