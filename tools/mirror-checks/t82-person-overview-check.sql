-- Mirror T8.2 check: one-person overview (database part). Finding 5: a coordinator's word changes to a need go into the need's own
-- history with what it was before; the person's own edits stay quiet. Finding 6: the two reflection intros point to the lists.
-- The overview sections use the existing gated functions (needs, strengths, plan, progress, milestone confirm) as the coordinator.
-- Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t82-person-overview-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; n int; ok boolean; nd uuid; nh uuid; ms uuid; t text;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; cx text;
begin
  insert into auth.users (id, email) values (ua, 'check.oa@example.invalid'), (uc, 'check.ocx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.oa@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.ocx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, safety_sensitive) values ('check.oa@example.invalid', 'CHECK OA', x, true) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.ocx@example.invalid', 'CHECK OCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- the person: an everyday need, a private health need, a strength, a goal reached (automatic milestone); shares general + health "see and change"
  perform set_config('request.jwt.claims', pa, true);
  nd := (public.mirror_need_save(null, 'housing', 'Bed', null, 'soon') ->> 'id')::uuid;
  nh := (public.mirror_need_save(null, 'physical_health', 'Glasses', null, 'soon') ->> 'id')::uuid;
  perform public.mirror_need_save(nd, 'housing', 'A bed', null, 'soon');           -- the person's own edit: no history line
  perform public.mirror_strength_save(null, 'skill', 'Cooking', null, 'food');
  perform public.mirror_goal_save((public.mirror_goal_save(null, '{"dimension":"identity_legal","title":"State ID"}') ->> 'id')::uuid,
    '{"dimension":"identity_legal","title":"State ID","status":"achieved"}');
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform public.mirror_my_consent_set(x, 'health', 'edit');
  select count(*) into n from jsonb_array_elements(public.mirror_need_history(nd));
  ok := n = 1;
  r := r || format('1 the person''s own word change leaves no extra history line (%s line): %s', n, ok);

  -- 2. the coordinator changes the words and urgency: one history line, by a coordinator, status unchanged, with the old words
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_need_save(nd, 'housing', 'A bed and a frame', 'Twin size', 'urgent', a);
  j := public.mirror_need_history(nd);
  ok := jsonb_array_length(j) = 2 and j -> 0 ->> 'by_role' = 'coordinator' and j -> 0 ->> 'from' = j -> 0 ->> 'to'
    and j -> 0 ->> 'note' ~ 'the words \(they were: "A bed"\)' and j -> 0 ->> 'note' ~ 'the details' and j -> 0 ->> 'note' ~ 'how soon \(it was: soon\)';
  perform public.mirror_need_save(nd, 'housing', 'A bed and a frame', 'Twin size', 'urgent', a);   -- no change: no line
  ok := ok and jsonb_array_length(public.mirror_need_history(nd)) = 2;
  r := r || format('2 coordinator''s change: 1 history line (coordinator, status kept, old words, details, how soon); saving nothing new adds nothing: %s', ok);

  -- 3. the overview sections as the coordinator: needs (both), strengths, plan with the milestone, progress; safety flag on the list
  j := public.mirror_needs_list(a);
  ok := jsonb_array_length(j -> 'needs') = 2 and (j -> 'can_add') ? 'health';
  ok := ok and jsonb_array_length(public.mirror_strengths(a) -> 'strengths') = 1;
  j := public.mirror_plan(a);
  ok := ok and jsonb_array_length(j -> 'milestones') = 0;           -- the ID goal is in the legal topic, not shared
  ok := ok and (select (e ->> 'safety_sensitive')::boolean from jsonb_array_elements(public.mirror_people(x)) e where e ->> 'id' = a::text);
  ok := ok and jsonb_array_length(public.mirror_progress(a) -> 'areas') = 15;
  r := r || format('3 coordinator overview: 2 needs (health shared), 1 strength, legal milestone not shown, progress 15 areas, safety mode on the list: %s', ok);

  -- 4. confirm: a need got (obtained -> confirmed met) and a milestone once legal is shared; taking a confirmation back
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_need_status(nh, 'obtained', null);
  perform public.mirror_my_consent_set(x, 'legal', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_need_status(nh, 'verified', null);
  ok := j ->> 'status' = 'verified';
  select (e ->> 'id')::uuid into ms from jsonb_array_elements(public.mirror_plan(a) -> 'milestones') e limit 1;
  ok := ok and ms is not null and (public.mirror_milestone_confirm(ms, true) ->> 'verified')::boolean
    and not (public.mirror_milestone_confirm(ms, false) ->> 'verified')::boolean;
  r := r || format('4 coordinator confirms a need met and a milestone (and can take it back): %s', ok);

  -- 5. finding 6: both reflections point to the lists
  execute 'reset role';
  select string_agg(intro, ' ') into t from mirror.question_sets where key in ('reflection_needs', 'reflection_assets');
  ok := t ~ 'My needs list' and t ~ 'My strengths list';
  r := r || format('5 the Needs and Assets reflections say where the lists are: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
