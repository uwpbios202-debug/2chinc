-- Mirror T9.1 check: email words, the one queue, the person's choices and safety mode, and the hold (nothing reaches the outbox until
-- the main admin turns a kind on). Fictional people and a made-up admin; always rolled back (no email is sent: outbox rows vanish with it).
do $chk$
declare
  r text[] := '{}'; a uuid; b uuid; j jsonb; m jsonb; ok boolean; s text; n0 int; n1 int;
  ua uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); ja text; up uuid := gen_random_uuid(); sp uuid := gen_random_uuid(); jp text;
begin
  insert into auth.users (id, email) values (ua, 'check.ea@example.invalid'), (up, 'check.ep@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sa, ua, now(), now(), now(), 'aal2'), (sp, up, now(), now(), now(), 'aal2');
  ja := json_build_object('sub', ua, 'email', 'check.ea@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sa)::text;
  jp := json_build_object('sub', up, 'email', 'check.ep@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sp)::text;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.e1@example.invalid', 'CHECK E1') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name, safety_sensitive) values ('check.e2@example.invalid', 'CHECK E2', true) returning id into b;
  select count(*) into n0 from public.email_outbox;

  -- 1. the words: never a detail, always the sign-in link; safety mode says only 2nd Chance Housing
  m := mirror.email_html('mirror_appointment', '{"first_name":"Ann","when":"Tuesday at 10:00 AM","organization":"Org"}');
  ok := m ->> 'html' like '%https://2ndchinc.org/mirror/sign-in/%' and m ->> 'subject' = 'Reminder: an appointment on Tuesday at 10:00 AM'
    and (mirror.email_html('mirror_invite', '{"organization":"Org","safety":true}') ->> 'html') !~* 'mirror|Org'
    and (mirror.email_html('mirror_security', '{"safety":true}') ->> 'subject') = '2nd Chance Housing: a change to your account'
    and (mirror.email_html('mirror_invite', '{"first_name":"<b>x</b>"}') ->> 'html') like '%&lt;b&gt;%';
  begin perform mirror.email_html('mirror_other', '{}'); ok := false; exception when invalid_parameter_value then null; end;
  r := r || format('1 words: sign-in link, no details, safety mode neutral, names escaped: %s', ok);

  -- 2. THE HOLD: with no kind turned on, nothing reaches the outbox; every attempt is recorded as held
  update portal_settings set value = '' where key = 'mirror_email_kinds_enabled';
  s := mirror.email_queue('check.e1@example.invalid', 'mirror_referral', '{"ref":"x1"}', a);
  select count(*) into n1 from public.email_outbox;
  ok := s = 'held' and n1 = n0 and exists (select 1 from mirror.notifications where individual_id = a and status = 'held' and kind = 'mirror_referral');
  r := r || format('2 held while the kind is off; outbox unchanged: %s', ok);

  -- 3. turned on: queued to the outbox once; the same item again within 12 hours is skipped; the person's choice and safety mode win
  update portal_settings set value = 'mirror_referral,mirror_security' where key = 'mirror_email_kinds_enabled';
  r := r || format('3dbg q1=%s q2=%s q3=%s', mirror.email_queue('check.e1@example.invalid', 'mirror_referral', '{"ref":"y2"}', a), mirror.email_queue('check.e1@example.invalid', 'mirror_referral', '{"ref":"y2"}', a), mirror.email_queue('check.e2@example.invalid', 'mirror_referral', '{"ref":"y3"}', b));
  ok := mirror.email_queue('check.e1@example.invalid', 'mirror_referral', '{"ref":"x2"}', a) = 'queued'
    and mirror.email_queue('check.e1@example.invalid', 'mirror_referral', '{"ref":"x2"}', a) = 'skipped'
    and mirror.email_queue('check.e2@example.invalid', 'mirror_referral', '{"ref":"x3"}', b) = 'skipped';
  insert into mirror.profiles (auth_email, notification_prefs) values ('check.e1@example.invalid', '{"referral": false}')
    on conflict (auth_email) do update set notification_prefs = '{"referral": false}';
  ok := ok and mirror.email_queue('check.e1@example.invalid', 'mirror_referral', '{"ref":"x4"}', a) = 'skipped'
    and mirror.email_queue('check.e2@example.invalid', 'mirror_security', '{}', b) = 'queued'
    and (select subject from public.email_outbox where to_email = 'check.e2@example.invalid' order by created_at desc limit 1) = '2nd Chance Housing: a change to your account';
  select count(*) into n1 from public.email_outbox;
  ok := ok and n1 = n0 + 2;
  r := r || format('3 on: queued once, repeats skipped, the person''s choice and safety mode respected, security neutral: %s', ok);

  -- 4. the admin page: a platform admin sees the words and counts; only the main admin switches; the switch is logged
  execute 'reset role';
  insert into mirror.organization_members (organization_id, auth_email, name, role) select id, 'check.ep@example.invalid', 'CHECK EP', 'org_admin' from mirror.organizations where is_platform_owner;
  insert into mirror.organization_members (organization_id, auth_email, name, role) select id, 'check.ea@example.invalid', 'CHECK EA', 'org_admin' from mirror.organizations where is_platform_owner;
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.ep@example.invalid', 'CHECK EP', 'check'), ('check.ea@example.invalid', 'CHECK EA', 'check');
  insert into public.portal_admins (email) values ('check.ea@example.invalid');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jp, true);
  j := public.mirror_admin_email_kinds();
  ok := jsonb_array_length(j -> 'kinds') = 6 and not (j ->> 'can_switch')::boolean
    and (select (k ->> 'enabled')::boolean and (k ->> 'queued')::int >= 1 from jsonb_array_elements(j -> 'kinds') k where k ->> 'kind' = 'mirror_referral');
  begin perform public.mirror_admin_email_kind_set('mirror_action', true); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', ja, true);
  j := public.mirror_admin_email_kind_set('mirror_action', true);
  j := public.mirror_admin_email_kind_set('mirror_referral', false);
  execute 'reset role';
  ok := ok and (select value from portal_settings where key = 'mirror_email_kinds_enabled') = 'mirror_security,mirror_action'
    and exists (select 1 from mirror.audit_logs where actor_email = 'check.ea@example.invalid' and table_name = 'portal_settings' and reason = 'mirror_action turned on');
  r := r || format('4 platform admins see words and counts; only the main admin switches (logged): %s', ok);

  -- 5. closed: the queue and the words cannot be called from a browser; the table is closed; anon refused
  ok := not has_function_privilege('authenticated', 'mirror.email_queue(text, text, jsonb, uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_admin_email_kinds()', 'execute')
    and not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'mirror' and g.table_name = 'notifications'
                    and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
    and (select value from portal_settings where key = 'mirror_email_kinds_enabled') is not null;
  r := r || format('5 queue, words and table closed to browsers: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
