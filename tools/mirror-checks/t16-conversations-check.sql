-- Mirror T1.6 check: the conversation guide saves. Fictional people and organizations; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; b uuid; cv uuid; cv2 uuid; j jsonb; n int; ok boolean;
  f_rent uuid; f_health uuid; f_mental uuid; f_pop uuid; ref1 uuid; ref2 uuid; need1 uuid;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); ud uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sc1 uuid := gen_random_uuid(); sd uuid := gen_random_uuid();
  pa text; pb text; cx text; c1 text; dy text;
begin
  insert into auth.users (id, email) values (ua, 'check.ca@example.invalid'), (ub, 'check.cb@example.invalid'),
    (uc, 'check.ccx@example.invalid'), (ud, 'check.cdy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sc, uc, now(), now(), now()), (sc1, uc, now(), now(), now()), (sd, ud, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ca@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.cb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.ccx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  c1 := json_build_object('sub', uc, 'email', 'check.ccx@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sc1)::text;
  dy := json_build_object('sub', ud, 'email', 'check.cdy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sd)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) select 'CHECK ORG Y', kind from mirror.organizations where id = x returning id into y;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ca@example.invalid', 'CHECK CA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.cb@example.invalid', 'CHECK CB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.ccx@example.invalid', 'CHECK CCX', 'coordinator'), (y, 'check.cdy@example.invalid', 'CHECK CDY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the person starts, answers, clears an answer; one open conversation; bad input refused
  perform set_config('request.jwt.claims', pa, true);
  cv := public.mirror_conversation_start();
  ok := public.mirror_conversation_start() = cv;
  perform public.mirror_conversation_answer_save(cv, 'home', 'Staying at my sister''s with my two kids. We have to be out by the end of the month.');
  perform public.mirror_conversation_answer_save(cv, 'money', 'I am behind on rent.');
  perform public.mirror_conversation_answer_save(cv, 'day', 'My daughter has asthma.');
  perform public.mirror_conversation_answer_save(cv, 'money', '   ');
  begin perform public.mirror_conversation_answer_save(cv, 'nope', 'x'); ok := false; exception when invalid_parameter_value then null; end;
  j := public.mirror_conversation_mine();
  ok := ok and jsonb_array_length(j -> 'conversations') = 1 and (j -> 'conversations' -> 0 -> 'answers') ? 'home'
    and not ((j -> 'conversations' -> 0 -> 'answers') ? 'money') and jsonb_array_length(j -> 'organizations') = 1;
  r := r || format('1 start (one open), answers saved, blank clears, bad question refused, own orgs listed: %s', ok);

  -- 2. what I heard: two shared (one private), one not shared, one about the person; wrong org and unknown meaning refused
  begin perform public.mirror_conversation_share(cv, y, '[]'::jsonb); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.mirror_conversation_share(cv, x, '[{"kind":"help","key":"Free money"}]'::jsonb); ok := false; exception when invalid_parameter_value then null; end;
  j := public.mirror_conversation_share(cv, x, '[
    {"kind":"help","key":"Emergency rental assistance","shared":true,"quotes":[{"q":"money","words":"I am behind on rent."}]},
    {"kind":"other","key":"health","shared":true,"quotes":[{"q":"day","words":"My daughter has asthma."}]},
    {"kind":"other","key":"mental","shared":false,"quotes":[{"q":"day","words":"Stressed."}]},
    {"kind":"pop","key":"Families with children","shared":true,"quotes":[{"q":"home","words":"with my two kids"}]}]'::jsonb);
  ok := ok and jsonb_array_length(j) = 4;
  execute 'reset role';
  select id into f_rent from mirror.conversation_findings where conversation_id = cv and key = 'Emergency rental assistance';
  select id into f_health from mirror.conversation_findings where conversation_id = cv and key = 'health';
  select id into f_mental from mirror.conversation_findings where conversation_id = cv and key = 'mental';
  select id into f_pop from mirror.conversation_findings where conversation_id = cv and key = 'Families with children';
  perform set_config('role', 'authenticated', true);
  begin perform public.mirror_conversation_answer_save(cv, 'home', 'more'); ok := false; exception when invalid_parameter_value then null; end;
  r := r || format('2 shared with own org only; unknown meaning refused; 4 findings saved; answering closed after sharing: %s', ok);

  -- 3. coordinator: sees the 3 ticked findings, 1 counted as not shared, never the answers; private look logged
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_conversations_shared(a, x);
  ok := jsonb_array_length(j -> 'conversations') = 1 and jsonb_array_length(j -> 'conversations' -> 0 -> 'findings') = 3
    and (j -> 'conversations' -> 0 ->> 'not_shared')::int = 1 and not (j::text like '%Staying at my sister%')
    and not (j::text like '%Stressed%');
  begin perform public.mirror_conversations_shared(a, y); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', c1, true);
  begin perform public.mirror_conversations_shared(a, x); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', dy, true);
  begin perform public.mirror_conversations_shared(a, y); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and actor_role = 'coordinator' and action = 'view' and category = 'health'
    and table_name = 'conversation_findings';
  ok := ok and n = 1;
  r := r || format('3 coordinator sees 3 ticked, 1 not-shared count, no answers or unticked words; other org / no authenticator refused; private look logged (%s): %s', n, ok);
  perform set_config('role', 'authenticated', true);

  -- 4. needs: coordinator needs "see and change"; then adds; no double; a fact about the person is not a need; the person adds their own
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_conversation_need(f_rent, x); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_conversation_need(f_rent, x);
  need1 := (j ->> 'id')::uuid;
  ok := ok and j ->> 'title' = 'Emergency rental assistance' and j ->> 'detail' like '%"I am behind on rent."%' and j ->> 'dimension' = 'housing';
  begin perform public.mirror_conversation_need(f_rent, x); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_conversation_need(f_pop, x); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_conversation_need(f_mental, x); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_conversation_need(f_health);
  ok := ok and j ->> 'category' = 'health';
  execute 'reset role';
  ok := ok and (select need_id from mirror.conversation_findings where id = f_rent) = need1;
  perform set_config('role', 'authenticated', true);
  r := r || format('4 coordinator adds a need only with edit OK; no double; not for facts or unshared items; the person adds the private one: %s', ok);

  -- 5. referrals: linked only when the caller made it, only on a shared item
  execute 'reset role';
  insert into public.chpms_referrals (org_name, made_by_email, made_by_role, first_name, last_name, consent_name, consent_on, phone)
    values ('CHECK PROGRAM ORG', 'check.ccx@example.invalid', 'staff', 'Check', 'Person', 'Check Person', current_date, '555-0100') returning id into ref1;
  insert into public.chpms_referrals (org_name, made_by_email, made_by_role, first_name, last_name, consent_name, consent_on, phone)
    values ('CHECK OTHER', 'someone.else@example.invalid', 'staff', 'Check', 'Person', 'Check Person', current_date, '555-0100') returning id into ref2;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_conversation_referral_log(f_rent, x, ref1);
  ok := jsonb_array_length(j -> 'referrals') = 1 and j -> 'referrals' -> 0 ->> 'org_name' = 'CHECK PROGRAM ORG';
  begin perform public.mirror_conversation_referral_log(f_rent, x, ref2); ok := false; exception when no_data_found then null; end;
  begin perform public.mirror_conversation_referral_log(f_mental, x, ref1); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('5 referral linked; someone else''s referral and an unshared item refused: %s', ok);

  -- 6. phrases: plain words only, known meanings only, per organization; the person's page gets them; retire
  j := public.mirror_listen_phrase_add(x, '  Rent   Man ', 'help', 'Emergency rental assistance');
  ok := jsonb_array_length(j) >= 1 and exists (select 1 from jsonb_array_elements(j) e where e ->> 'phrase' = 'rent man');
  begin perform public.mirror_listen_phrase_add(x, 'rent.*', 'help', 'Emergency rental assistance'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_listen_phrase_add(x, 'rent man', 'help', 'Free money'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_listen_phrase_add(y, 'rent man', 'help', 'Emergency rental assistance'); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  ok := ok and exists (select 1 from jsonb_array_elements(public.mirror_conversation_mine() -> 'phrases') e where e ->> 'phrase' = 'rent man');
  perform set_config('request.jwt.claims', dy, true);
  begin perform public.mirror_listen_phrases(x); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_listen_phrase_retire((select (e ->> 'id')::uuid from jsonb_array_elements(public.mirror_listen_phrases(x)) e where e ->> 'phrase' = 'rent man'));
  ok := ok and not exists (select 1 from jsonb_array_elements(j) e where e ->> 'phrase' = 'rent man');
  r := r || format('6 phrase added (tidied), patterns and unknown meanings refused, other org refused, person''s page gets it, retired: %s', ok);

  -- 7. the person takes it back: kept, nothing shared, coordinator sees none; discard refused (referral); a new one starts
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_conversation_share(cv, null, '[{"kind":"help","key":"Emergency rental assistance","shared":true,"quotes":[]}]'::jsonb);
  execute 'reset role';
  ok := (select status from mirror.conversations where id = cv) = 'kept'
    and not exists (select 1 from mirror.conversation_findings where conversation_id = cv and shared)
    and exists (select 1 from mirror.conversation_findings where id = f_health)          -- removed from the list but kept: it is a need
    and not exists (select 1 from mirror.conversation_findings where id = f_mental);     -- removed and nothing hangs on it: gone
  perform set_config('role', 'authenticated', true);
  begin perform public.mirror_conversation_discard(cv); ok := false; exception when invalid_parameter_value then null; end;
  cv2 := public.mirror_conversation_start();
  ok := ok and cv2 <> cv;
  perform public.mirror_conversation_discard(cv2);
  ok := ok and jsonb_array_length(public.mirror_conversation_mine() -> 'conversations') = 1;
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and jsonb_array_length(public.mirror_conversations_shared(a, x) -> 'conversations') = 0;
  r := r || format('7 taken back -> kept, nothing shared; removed items gone unless a need; discard refused after a referral; new one starts and can be thrown away: %s', ok);

  -- 8. download; another person sees and touches nothing
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_conversations();
  ok := jsonb_array_length(j) = 1 and j -> 0 -> 'answers' ? 'home'
    and exists (select 1 from jsonb_array_elements(j -> 0 -> 'what_was_heard') e where e -> 'referrals' -> 0 ->> 'to' = 'CHECK PROGRAM ORG');
  perform set_config('request.jwt.claims', pb, true);
  ok := ok and jsonb_array_length(public.mirror_conversation_mine() -> 'conversations') = 0;
  begin perform public.mirror_conversation_answer_save(cv, 'home', 'x'); ok := false; exception when no_data_found then null; end;
  begin perform public.mirror_conversation_share(cv, x, '[]'::jsonb); ok := false; exception when no_data_found then null; end;
  begin perform public.mirror_conversation_need(f_health); ok := false; exception when others then null; end;
  r := r || format('8 download has answers, findings and the referral; another person sees none and cannot change any: %s', ok);

  -- 9. tables closed to browsers; deleting the whole Mirror removes it all
  execute 'reset role';
  ok := not has_table_privilege('authenticated', 'mirror.conversations', 'select') and not has_table_privilege('anon', 'mirror.conversation_answers', 'select')
    and not has_table_privilege('authenticated', 'mirror.listen_phrases', 'insert') and not has_table_privilege('authenticated', 'mirror.conversation_findings', 'select');
  delete from mirror.individuals where id = a;
  ok := ok and not exists (select 1 from mirror.conversations where id = cv) and not exists (select 1 from mirror.conversation_findings where id in (f_rent, f_health));
  r := r || format('9 tables closed to browsers; deleting the Mirror removes conversations and findings: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
