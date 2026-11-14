-- Phase N TN.5 check: check-ins from the first meeting, and linking a check-in to a Mirror need inside the Mirror.
-- Fictional Navigator and people (files marked sample, so no email); always rolled back.
do $chk$
declare
  r text[] := '{}'; n1 uuid; p uuid; q uuid; org uuid; ind uuid; nd uuid; nh uuid; fid uuid; j jsonb; ok boolean; k int;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); up uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); sp uuid := gen_random_uuid(); j1 text; j1m text; j2 text; jp text;
begin
  insert into auth.users (id, email) values (u1, 'check.ka@example.invalid'), (u2, 'check.kb@example.invalid'), (up, 'check.kp@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values
    (s1, u1, now(), now(), now(), 'aal2'), (s2, u2, now(), now(), now(), 'aal2'), (sp, up, now(), now(), now(), 'aal1');
  j1 := json_build_object('sub', u1, 'email', 'check.ka@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s1)::text;
  j1m := json_build_object('sub', u1, 'email', 'check.ka@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', s1)::text;
  j2 := json_build_object('sub', u2, 'email', 'check.kb@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', s2)::text;
  jp := json_build_object('sub', up, 'email', 'check.kp@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sp)::text;
  insert into navigators (name, email, status) values ('CHECK Keeper', 'check.ka@example.invalid', 'pilot') returning id into n1;
  insert into nav_referrals (navigator_id, first_name, last_name, is_sample, consent_name, consent_on, status, checkin_every)
    values (n1, 'Check', 'Early', true, 'Check Early', current_date, 'searching', 'weekly') returning id into p;
  insert into nav_referrals (navigator_id, first_name, is_sample, status) values (n1, 'Check', true, 'draft') returning id into q;

  -- 1. a plan before housing: the first check-in is on the calendar; no plan without the housing consent
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_checkin_plan_save(p, 'weekly', current_date + 3, 'meet at the library');
  perform public.nav_checkin_plan_save(q, 'weekly', current_date + 3, null);
  execute 'reset role';
  ok := (select count(*) from nav_followups where referral_id = p and mark = 'checkin' and done_on is null and due_on = current_date + 3) = 1
    and (select next_checkin_on from nav_referrals where id = p) = current_date + 3
    and not exists (select 1 from nav_followups where referral_id = q);
  r := r || format('1 check-ins start at the first meeting (after the housing consent only): %s', ok);

  -- 2. recording one before housing schedules the next (a week later); closing before move-in clears the open one
  select id into fid from nav_followups where referral_id = p and mark = 'checkin' and done_on is null;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_followup_save(fid, 'stable', null, 'Talked about ID and food');
  execute 'reset role';
  ok := (select count(*) from nav_followups where referral_id = p and mark = 'checkin' and done_on is null and due_on = current_date + 7) = 1
    and not exists (select 1 from nav_earnings e where e.referral_id = p and e.kind like 'retention%');
  r := r || format('2dbg %s', (select string_agg(kind || '/' || status, ',') from nav_earnings where referral_id = p));
  r := r || format('2 the next check-in is scheduled after one is recorded; no retention pay before housing: %s', ok);

  -- 3. the Mirror: the Navigator's organization lists the check-ins and the needs it may see, and links one (authenticator code)
  org := mirror.navigator_org(n1, true);
  insert into mirror.individuals (auth_email, preferred_name) values ('check.kp@example.invalid', 'CHECK KP') returning id into ind;
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (org, ind, 'active');
  update nav_referrals set mirror_individual_id = ind where id = p;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jp, true);
  nd := (public.mirror_need_save(null, 'housing', 'A place of my own', null, 'urgent') ->> 'id')::uuid;
  nh := (public.mirror_need_save(null, 'physical_health', 'See a dentist', null, 'soon') ->> 'id')::uuid;
  perform set_config('request.jwt.claims', j1m, true);
  j := public.mirror_nav_checkins(ind);
  ok := jsonb_array_length(j -> 'checkins') = 2
    and exists (select 1 from jsonb_array_elements(j -> 'needs') e where e ->> 'id' = nd::text)
    and not exists (select 1 from jsonb_array_elements(j -> 'needs') e where e ->> 'id' = nh::text);
  begin perform public.mirror_nav_checkin_link(fid, nh); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('3 the Mirror lists check-ins and only shared needs; a private need cannot be linked: %s', ok);

  -- 4. with "see and change" for everyday topics the coordinator links; the Navigator portal (no authenticator) cannot open it
  execute 'reset role';
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (ind, org, 'general', 'edit', 'check.kp@example.invalid');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1m, true);
  j := public.mirror_nav_checkin_link(fid, nd);
  ok := exists (select 1 from jsonb_array_elements(j -> 'checkins') e where e ->> 'id' = fid::text and e ->> 'need_title' = 'A place of my own');
  perform set_config('request.jwt.claims', j1, true);
  begin perform public.mirror_nav_checkins(ind); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('4 linked to a Mirror need in the Mirror; refused without the authenticator: %s', ok);

  -- 5. another organization's coordinator cannot see them
  execute 'reset role';
  insert into mirror.organization_members (organization_id, auth_email, name, role)
    select id, 'check.kb@example.invalid', 'CHECK KB', 'coordinator' from mirror.organizations where is_platform_owner;
  insert into mirror.organization_individuals (organization_id, individual_id, status) select id, ind, 'active' from mirror.organizations where is_platform_owner;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j2, true);
  ok := true;
  begin perform public.mirror_nav_checkins(ind); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_nav_checkin_link(fid, null); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('5 another organization is refused: %s', ok);

  -- 6. closing before move-in clears the open check-in; reminders still only for people who moved in; closed to anon
  perform set_config('request.jwt.claims', j1, true);
  perform public.nav_referral_step(p, 'closed', '{"close_reason":"no_contact"}');
  execute 'reset role';
  ok := not exists (select 1 from nav_followups where referral_id = p and done_on is null)
    and (select next_checkin_on from nav_referrals where id = p) is null
    and pg_get_functiondef('public.nav_followup_reminders'::regproc) like '%r.status = ''moved_in''%'
    and not has_function_privilege('anon', 'public.mirror_nav_checkins(uuid, uuid)', 'execute');
  r := r || format('6 closing before move-in clears it; reminders unchanged; closed to anon: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
