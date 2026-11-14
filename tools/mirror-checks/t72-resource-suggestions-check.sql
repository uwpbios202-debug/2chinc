-- Mirror T7.2 check: resource suggestions from needs, place and groups; statuses; who may confirm eligibility. Fictional people;
-- always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; k jsonb; n int; ok boolean; s1 uuid; s2 uuid; h uuid; f uuid; ph uuid;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid();
  pa text; pb text; cx text; c1 text; p1 text; p2 text; pf text; dnr text;
begin
  insert into auth.users (id, email) values (ua, 'check.ra@example.invalid'), (ub, 'check.rb@example.invalid'), (uc, 'check.rcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now()), (sc1, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ra@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.rb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.rcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.rcx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ra@example.invalid', 'CHECK RA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.rb@example.invalid', 'CHECK RB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.rcx@example.invalid', 'CHECK RCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  -- a program of the "do not refer" organization (made up inside this transaction if that organization has none)
  select p.program_id into dnr from public.chpms_programs p join public.chpms_orgs o on o.org_id = p.org_id where o.our_relationship = 'do_not_refer' limit 1;
  if dnr is null then
    insert into public.chpms_programs (program_id, org_id, program_name)
      select 'CHECK-T72-DNR', org_id, 'CHECK do-not-refer program' from public.chpms_orgs where our_relationship = 'do_not_refer' limit 1;
    insert into public.chpms_program_assist (program_id, category, provided) values ('CHECK-T72-DNR', 'Emergency rental assistance', true);
    dnr := 'CHECK-T72-DNR';
  end if;
  perform set_config('role', 'authenticated', true);

  -- 1. the person's open needs bring up to 3 programs each, never a do-not-refer one, never the same program twice, no open/closed claims
  perform set_config('request.jwt.claims', pa, true);
  h := (public.mirror_need_save(null, 'housing', 'A place of my own', null, 'urgent') ->> 'id')::uuid;
  f := (public.mirror_need_save(null, 'finances', 'Help with a budget', null, 'later') ->> 'id')::uuid;
  ph := (public.mirror_need_save(null, 'physical_health', 'A dentist', null, 'soon') ->> 'id')::uuid;
  j := public.mirror_resources();
  select count(*) into n from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p;
  ok := (j ->> 'self')::boolean and jsonb_array_length(j -> 'matches') = 3
    and j -> 'matches' -> 0 ->> 'need_title' = 'A place of my own' and jsonb_array_length(j -> 'matches' -> 0 -> 'programs') >= 3
    and jsonb_array_length(j -> 'matches' -> 2 -> 'programs') >= 1
    and jsonb_array_length(j -> 'matches' -> 1 -> 'programs') >= 1    -- physical health: found since TN.3 (Progressive Community Health Centers)
    and not exists (select 1 from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p where p ->> 'program_id' = dnr)
    and (select count(distinct p ->> 'program_id') from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p) = n
    and not exists (select 1 from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p
                     where p ? 'current_status' or p ? 'currently_open' or p ? 'waiting_list')
    and j -> 'profile' ->> 'place' is null and jsonb_array_length(j -> 'list') = 0;
  p1 := j -> 'matches' -> 0 -> 'programs' -> 0 ->> 'program_id';
  p2 := j -> 'matches' -> 0 -> 'programs' -> 1 ->> 'program_id';
  pf := j -> 'matches' -> 2 -> 'programs' -> 0 ->> 'program_id';
  r := r || format('1 matches: housing %s, health 1 or more (TN.3), money %s; %s programs, none repeated, no do-not-refer, no availability claims: %s',
                   jsonb_array_length(j -> 'matches' -> 0 -> 'programs'), jsonb_array_length(j -> 'matches' -> 2 -> 'programs'), n, ok);

  -- 2. place and groups narrow the matches; bad input refused; a coordinator never gets them
  perform public.mirror_resource_profile_save('outside', null);
  j := public.mirror_resources();
  ok := not exists (select 1 from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p where p ->> 'serves' !~* 'national');
  perform public.mirror_resource_profile_save('milwaukee_city', array['Veterans']);
  j := public.mirror_resources();
  ok := ok and j -> 'profile' ->> 'place' = 'milwaukee_city' and (j -> 'profile' ->> 'groups_answered')::boolean
    and not exists (select 1 from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p
                     where jsonb_array_length(p -> 'for') > 0
                       and not exists (select 1 from jsonb_array_elements_text(p -> 'for') g
                                        where g not in ('Seniors', 'Returning citizens', 'Families with children', 'Disabilities')));
  begin perform public.mirror_resource_profile_save('mars', null); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_resource_profile_save('wisconsin', array['Pirates']); ok := ok and false; exception when invalid_parameter_value then null; end;
  -- back to no place, so the saved programs below are the ones from step 1
  perform public.mirror_resource_profile_save(null, '{}');
  r := r || format('2 place "outside" leaves only national programs; groups leave out programs only for other groups; bad input refused: %s', ok);

  -- 3. saving: status "suggested", label on, gone from matches; repeat refused; the person cannot confirm eligibility; applied keeps the label
  k := public.mirror_resource_save(p1, h);
  s1 := (k ->> 'id')::uuid;
  ok := k ->> 'status' = 'suggested' and (k ->> 'suggested_label')::boolean and k ->> 'need_title' = 'A place of my own' and not (k ->> 'private')::boolean;
  j := public.mirror_resources();
  ok := ok and not exists (select 1 from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p where p ->> 'program_id' = p1)
    and jsonb_array_length(j -> 'list') = 1;
  begin perform public.mirror_resource_save(p1, h); ok := ok and false; exception when unique_violation then null; end;
  begin perform public.mirror_resource_save(dnr, h); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_resource_status(s1, 'eligibility_confirmed', 'I think so'); ok := ok and false; exception when insufficient_privilege then null; end;
  k := public.mirror_resource_status(s1, 'applied', 'Applied online 11/14');
  ok := ok and k ->> 'status' = 'applied' and (k ->> 'suggested_label')::boolean and jsonb_array_length(k -> 'history') = 2;
  s2 := (public.mirror_resource_save(pf, f) ->> 'id')::uuid;     -- money need: a private (financial) one
  r := r || format('3 saved as suggested (label on), left the matches, repeat and do-not-refer refused, person cannot confirm, applied keeps label: %s', ok);

  -- 4. coordinator who may only see: sees the everyday one, not the private one, no place or groups, no matches, cannot save or change
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_resources(a);
  ok := not (j ->> 'self')::boolean and jsonb_array_length(j -> 'list') = 1 and j -> 'list' -> 0 ->> 'id' = s1::text
    and j -> 'profile' = 'null'::jsonb and j -> 'household_groups' = 'null'::jsonb and not (j ? 'hidden')
    and jsonb_array_length(j -> 'matches') = 0;
  begin perform public.mirror_resource_save(p2, h, a); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_resource_status(s1, 'enrolled'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_resource_status(s2, 'declined'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_resource_profile_save('wisconsin', null); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator (view only): 1 of 2 (private one hidden, no hidden count), no place/groups, no matches, cannot save or change: %s', ok);

  -- 5. with "see and change" for everyday topics: confirms eligibility only with a note; label off; cannot remove; adds one (marked theirs);
  --    without the authenticator refused; person B sees nothing of A's; back to "suggested" takes the confirmation off
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_resource_status(s1, 'eligibility_confirmed', '  '); ok := false; exception when invalid_parameter_value then ok := true; end;
  k := public.mirror_resource_status(s1, 'eligibility_confirmed', 'Called the program 11/20; they qualify');
  ok := ok and k ->> 'status' = 'eligibility_confirmed' and not (k ->> 'suggested_label')::boolean and k ->> 'confirmed_by_role' = 'coordinator';
  begin perform public.mirror_resource_delete(s1); ok := ok and false; exception when insufficient_privilege then null; end;
  k := public.mirror_resource_save(p2, h, a);
  ok := ok and k ->> 'source' = 'coordinator' and k ->> 'added_by_role' = 'coordinator'
    and jsonb_array_length(public.mirror_resources(a) -> 'matches') >= 1;
  begin perform public.mirror_resource_status(s2, 'declined'); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_resources(a); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pb, true);
  ok := ok and jsonb_array_length(public.mirror_resources() -> 'list') = 0;
  begin perform public.mirror_resource_status(s1, 'declined'); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_resource_delete(s1); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_resources(a); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  k := public.mirror_resource_status(s1, 'suggested', null);
  ok := ok and (k ->> 'suggested_label')::boolean and k ->> 'confirmed_at' is null and jsonb_array_length(k -> 'history') = 4;
  r := r || format('5 with edit sharing: confirm needs a note, label off, cannot remove, adds marked theirs; aal1 and person B refused; back to suggested clears it: %s', ok);

  -- 6. the person removes one, downloads the rest with history; enrolled drops the label; tables and helpers closed to browsers
  ok := public.mirror_resource_delete(s2);
  k := public.mirror_resource_status(s1, 'enrolled', null);
  ok := ok and not (k ->> 'suggested_label')::boolean;
  j := public.mirror_my_export_resources();
  ok := ok and jsonb_array_length(j -> 'programs') = 2 and j -> 'where_and_groups' ->> 'place' is null
    and exists (select 1 from jsonb_array_elements(j -> 'programs') e where e ->> 'added_by' = 'coordinator')
    and exists (select 1 from jsonb_array_elements(j -> 'programs') e where jsonb_array_length(e -> 'history') = 5);
  execute 'reset role';
  ok := ok and not has_table_privilege('authenticated', 'mirror.resource_suggestions', 'select')
     and not has_table_privilege('authenticated', 'mirror.resource_profiles', 'select')
     and not has_table_privilege('anon', 'mirror.resource_suggestion_events', 'select')
     and not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'mirror'
                      and g.table_name in ('resource_suggestions', 'resource_profiles', 'resource_suggestion_events') and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
     and not has_function_privilege('anon', 'public.mirror_resources(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'mirror.resource_matches(uuid, boolean)', 'execute')
     and not has_function_privilege('authenticated', 'mirror.resource_program_json(text)', 'execute');
  ok := ok and not mirror.place_served('City of West Allis', 'milwaukee_city') and mirror.place_served('City of West Allis', 'milwaukee_county')
     and mirror.place_served('National (listed by City of Wauwatosa)', 'outside') and not mirror.place_served('Milwaukee County', 'wisconsin')
     and not mirror.place_served('Milwaukee County (HCV jurisdiction excludes City of Milwaukee/HACM and West Allis unless ported)', 'milwaukee_city')
     and mirror.place_served('Greater Milwaukee / SE Wisconsin; all faiths', 'nearby_county') and not mirror.place_served('Greater Milwaukee / SE Wisconsin; all faiths', 'wisconsin');
  begin truncate mirror.resource_suggestions, mirror.resource_suggestion_events; ok := ok and false; exception when insufficient_privilege or feature_not_supported then null; end;   -- refused by the no-truncate guard, or (since T7.3) by the referrals foreign key
  select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'resource_suggestions';
  r := r || format('6 person removes one, enrolled drops the label, download has 2 with history; closed to browsers; place rules on 7 real area texts; %s audit rows: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
