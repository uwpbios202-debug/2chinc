-- Mirror T7.3 check: referrals with typed consent through the CHPMS rules, plus the chpms_referral_save fix. Fictional people;
-- always rolled back (the made-up staff member and the directory referrals vanish with it; staff referrals send no email).
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; k jsonb; n int; ok boolean; h uuid; s1 uuid; s2 uuid; sd uuid; f1 uuid; f2 uuid; cref uuid;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; pb text; cx text; cy text; p1 text; p2 text; dnr text; o1 text; hp text;
begin
  insert into auth.users (id, email) values (ua, 'check.fa@example.invalid'), (ub, 'check.fb@example.invalid'),
    (uc, 'check.fcx@example.invalid'), (uy, 'check.fcy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values
    (sa, ua, now(), now(), now(), 'aal1'), (sb, ub, now(), now(), now(), 'aal1'), (sc, uc, now(), now(), now(), 'aal2'), (sy, uy, now(), now(), now(), 'aal2');
  pa := json_build_object('sub', ua, 'email', 'check.fa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.fb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.fcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  cy := json_build_object('sub', uy, 'email', 'check.fcy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  insert into condo_staff (email, name) values ('check.fcx@example.invalid', 'CHECK FCX');        -- CX is office staff (CHPMS role), CY is not
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.fa@example.invalid', 'CHECK FA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.fb@example.invalid', 'CHECK FB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.fcx@example.invalid', 'CHECK FCX', 'coordinator'), (x, 'check.fcy@example.invalid', 'CHECK FCY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  select p.program_id into dnr from public.chpms_programs p join public.chpms_orgs o on o.org_id = p.org_id where o.our_relationship = 'do_not_refer' limit 1;
  if dnr is null then
    insert into public.chpms_programs (program_id, org_id, program_name)
      select 'CHECK-T73-DNR', org_id, 'CHECK do-not-refer program' from public.chpms_orgs where our_relationship = 'do_not_refer' limit 1;
    dnr := 'CHECK-T73-DNR';
  end if;
  select org_id into o1 from public.chpms_orgs where coalesce(our_relationship, '') <> 'do_not_refer' order by org_id limit 1;
  perform set_config('role', 'authenticated', true);

  -- 1. the CHPMS fix: office staff can now save a directory referral (it failed on the phone-or-email check before)
  perform set_config('request.jwt.claims', cx, true);
  begin
    cref := public.chpms_referral_save(jsonb_build_object('org_id', o1, 'first_name', 'Check', 'last_name', 'Plain', 'phone', '414-555-0100',
      'consent', true, 'consent_name', 'Check Plain'));
    ok := cref is not null;
  exception when others then ok := false; r := r || ('1 error: ' || sqlerrm); end;
  r := r || format('1 chpms_referral_save works again (directory referral saved with its phone): %s', ok);

  -- 2. the person saves two programs and asks 2nd Chance to refer them; no organization = refused; the same one twice = refused
  perform set_config('request.jwt.claims', pa, true);
  h := (public.mirror_need_save(null, 'housing', 'A place of my own', null, 'urgent') ->> 'id')::uuid;
  j := public.mirror_resources() -> 'matches' -> 0 -> 'programs';
  p1 := j -> 0 ->> 'program_id'; p2 := j -> 1 ->> 'program_id'; hp := j -> 0 -> 'help' ->> 0;
  s1 := (public.mirror_resource_save(p1, h) ->> 'id')::uuid;
  s2 := (public.mirror_resource_save(p2, h) ->> 'id')::uuid;
  begin perform public.mirror_referral_propose(s1, null); ok := false; exception when invalid_parameter_value then ok := true; end;
  k := public.mirror_referral_propose(s1, x, array[hp, 'Not a real help type'], 'Behind one month');
  f1 := (k ->> 'id')::uuid;
  ok := ok and k ->> 'status' = 'awaiting_consent' and k ->> 'proposed_by_role' = 'self' and k ->> 'ref_no' is null
    and not (k -> 'help_needed') ? 'Not a real help type' and (k -> 'help_needed') ? hp;
  begin perform public.mirror_referral_propose(s1, x); ok := ok and false; exception when unique_violation then null; end;
  -- a "do not refer" program (put on the list behind the page's back) cannot be proposed
  execute 'reset role';
  insert into mirror.resource_suggestions (individual_id, chpms_program_id, program_name, need_id, dimension_key, category, added_by, added_by_role)
    values (a, dnr, 'CHECK dnr', h, 'housing', 'general', 'check', 'self') returning id into sd;
  perform set_config('role', 'authenticated', true);
  begin perform public.mirror_referral_propose(sd, x); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('2 person asks an organization they work with; none chosen / twice / do-not-refer refused; unknown help types dropped: %s', ok);

  -- 3. consent: only the person; the typed name must match; a contact is needed; the exact words are kept
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_referral_consent(f1, 'Fa', 'Check', true, null, 2, 'Fa Check'); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pa, true);
  begin perform public.mirror_referral_consent(f1, 'Fa', 'Check', false, '414-555-0101', 2, 'Someone Else'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_referral_consent(f1, 'Fa', 'Check', false, null, 2, 'Fa Check'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_referral_consent(f1, 'Fa', 'Check', false, 'call me', 2, 'Fa Check'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_referral_send(f1); ok := ok and false; exception when insufficient_privilege then null; end;
  k := public.mirror_referral_consent(f1, 'Fa', 'Check', true, '414-555-0101', 2, '  fa   check ');
  ok := ok and k ->> 'status' = 'consented' and k ->> 'share_email' = 'check.fa@example.invalid' and k ->> 'share_phone' = '414-555-0101'
    and k ->> 'consent_text' like 'I agree that % may refer me to %' and k ->> 'consent_text' like '%my email, my phone, how many people live with me%'
    and k ->> 'consent_text' like '%' || hp || '%Behind one month%';
  begin perform public.mirror_referral_send(f1); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('3 only the person agrees; wrong typed name, no contact, bad phone refused; person cannot send; words kept: %s', ok);

  -- 4. coordinators: view-only sees it but cannot propose; with "see and change": CY (not office staff, field staff or Navigator) cannot
  --    send; CX sends through chpms_referral_save: directory row with phone, email, consent name and the consent words in the notes
  perform set_config('request.jwt.claims', cx, true);
  ok := jsonb_array_length(public.mirror_referrals(a) -> 'referrals') = 1 and not (public.mirror_referrals(a) ->> 'self')::boolean;
  begin perform public.mirror_referral_propose(s2); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cy, true);
  ok := ok and not (public.mirror_referrals(a) ->> 'can_send')::boolean;
  begin perform public.mirror_referral_send(f1); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and (public.mirror_referrals(a) ->> 'can_send')::boolean;
  k := public.mirror_referral_send(f1);
  ok := ok and k ->> 'status' = 'referred' and k ->> 'ref_no' is not null and k ->> 'directory_status' = 'new';
  execute 'reset role';
  ok := ok and exists (select 1 from public.chpms_referrals c join mirror.referrals m on m.chpms_referral_id = c.id
    where m.id = f1 and c.phone = '414-555-0101' and c.email = 'check.fa@example.invalid' and c.consent_name = 'fa check'
      and c.household_size = 2 and c.program_id = p1 and c.notes like '%Consent typed in the Human Mirror%' and c.made_by_role = 'staff');
  perform set_config('role', 'authenticated', true);
  begin perform public.mirror_referral_send(f1); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('4 view-only cannot propose; non-CHPMS coordinator cannot send; office staff sends via chpms_referral_save (row complete); no second send: %s', ok);

  -- 5. the person takes consent back: directory referral withdrawn (it was not sent yet) with a note; a coordinator's proposal the person
  --    declines; person B sees nothing of A's and cannot act on it
  perform set_config('request.jwt.claims', cx, true);
  f2 := (public.mirror_referral_propose(s2, null, null, null) ->> 'id')::uuid;
  begin perform public.mirror_referral_withdraw(f1); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pa, true);
  k := public.mirror_referral_withdraw(f1);
  ok := ok and k ->> 'status' = 'withdrawn' and k ->> 'directory_status' = 'withdrawn';
  k := public.mirror_referral_decline(f2);
  ok := ok and k ->> 'status' = 'declined';
  begin perform public.mirror_referral_consent(f2, 'Fa', 'Check', true, null, null, 'Fa Check'); ok := ok and false; exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claims', pb, true);
  ok := ok and jsonb_array_length(public.mirror_referrals() -> 'referrals') = 0;
  begin perform public.mirror_referral_withdraw(f1); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_referrals(a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and exists (select 1 from public.chpms_referral_events e join mirror.referrals m on m.chpms_referral_id = e.referral_id
                        where m.id = f1 and e.detail like 'The person took back consent in their Mirror%');
  perform set_config('role', 'authenticated', true);
  r := r || format('5 person takes consent back (directory referral withdrawn + note), declines a proposal; others cannot; B sees nothing: %s', ok);

  -- 6. download with the words agreed to and the history; tables and helpers closed to browsers; audit rows written
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_referrals();
  ok := jsonb_array_length(j) = 2 and exists (select 1 from jsonb_array_elements(j) e where e ->> 'consent_words' like 'I agree that %'
          and jsonb_array_length(e -> 'history') = 4);
  execute 'reset role';
  ok := ok and not has_table_privilege('authenticated', 'mirror.referrals', 'select') and not has_table_privilege('anon', 'mirror.referral_events', 'select')
     and not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'mirror'
                      and g.table_name in ('referrals', 'referral_events') and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
     and not has_function_privilege('anon', 'public.mirror_referral_send(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'mirror.referral_json(mirror.referrals)', 'execute')
     and has_function_privilege('authenticated', 'public.chpms_referral_save(jsonb)', 'execute')
     and not has_function_privilege('anon', 'public.chpms_referral_save(jsonb)', 'execute');
  begin truncate mirror.referrals, mirror.referral_events; ok := ok and false; exception when insufficient_privilege then null; end;
  select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'referrals';
  r := r || format('6 download has 2 with the words agreed to and history; closed to browsers; chpms_referral_save grants unchanged; %s audit rows: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
