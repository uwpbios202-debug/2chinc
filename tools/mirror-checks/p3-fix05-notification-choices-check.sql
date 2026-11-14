-- Check for Phase 3 finding 5 (migration 20261119283000): the person's email choices. Fictional people only; always rolled back.
-- Needs fresh sessions (Phase 2 fix 5): sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; ok boolean; p uuid; j jsonb; n int;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p3f5@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pb text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p3f5b@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p3f5@example.invalid', 'CHECK Person') returning id into p;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p3f5b@example.invalid', 'CHECK Other');
  perform set_config('role', 'authenticated', true);

  -- 1 defaults: all three on, safety mode off, sign-in and security always sent
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_notifications();
  ok := j -> 'choices' = '{"referral": true, "appointment": true, "action": true}'::jsonb and (j ->> 'safety_mode')::boolean = false
    and j -> 'always' = '["sign_in", "security"]'::jsonb;
  execute 'reset role';
  ok := ok and mirror.notification_ok('check.p3f5@example.invalid', 'mirror_referral') and mirror.notification_ok('check.p3f5@example.invalid', 'mirror_security')
    and not exists (select 1 from mirror.profiles where auth_email = 'check.p3f5@example.invalid');
  r := r || format('1 defaults all on, safety off, sign-in/security always; nothing stored until a save: %s', ok);

  -- 2 turning appointment reminders off is stored, read back, honored, and logged
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_notifications_set('{"appointment": false}');
  ok := j -> 'choices' = '{"referral": true, "appointment": false, "action": true}'::jsonb;
  j := public.mirror_my_notifications_set('{"action": false}');
  ok := ok and j -> 'choices' = '{"referral": true, "appointment": false, "action": false}'::jsonb;
  execute 'reset role';
  ok := ok and not mirror.notification_ok('check.p3f5@example.invalid', 'mirror_appointment') and not mirror.notification_ok('check.p3f5@example.invalid', 'mirror_action')
    and mirror.notification_ok('check.p3f5@example.invalid', 'mirror_referral');
  select count(*) into n from mirror.audit_logs where individual_id = p and action = 'notifications' and actor_role = 'self';
  r := r || format('2 two saves merge (appointment off, then plan off); referral still on; both logged (%s): %s', n, ok and n = 2);

  -- 3 wrong input refused, nothing changed
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  ok := true;
  begin perform public.mirror_my_notifications_set('{"newsletter": true}'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_my_notifications_set('{"referral": "yes"}'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_my_notifications_set('{}'); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_my_notifications_set(null); ok := false; exception when invalid_parameter_value then null; end;
  ok := ok and public.mirror_my_notifications() -> 'choices' = '{"referral": true, "appointment": false, "action": false}'::jsonb;
  r := r || format('3 unknown choice, non-true/false, empty and null refused; choices unchanged: %s', ok);

  -- 4 safety mode stops all three; security still goes; the page is told
  perform public.mirror_my_safety(true);
  ok := (public.mirror_my_notifications() ->> 'safety_mode')::boolean;
  execute 'reset role';
  ok := ok and not mirror.notification_ok('check.p3f5@example.invalid', 'mirror_referral') and mirror.notification_ok('check.p3f5@example.invalid', 'mirror_security');
  r := r || format('4 safety mode on: referral stopped, security still sent, page shows it: %s', ok);

  -- 5 another person keeps their own defaults; an address without a Mirror and an unknown kind get nothing but security
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pb, true);
  ok := public.mirror_my_notifications() -> 'choices' = '{"referral": true, "appointment": true, "action": true}'::jsonb;
  execute 'reset role';
  ok := ok and not mirror.notification_ok('nobody.p3f5@example.invalid', 'mirror_referral') and mirror.notification_ok('nobody.p3f5@example.invalid', 'mirror_security')
    and not mirror.notification_ok('check.p3f5b@example.invalid', 'mirror_invite') and mirror.notification_ok('CHECK.P3F5B@example.invalid', 'mirror_referral');
  r := r || format('5 other person separate; no Mirror -> security only; unknown kind never; email case ignored: %s', ok);

  -- 6 closed to browsers: the send check and the table are not reachable; anon cannot call the person's functions
  ok := not has_function_privilege('authenticated', 'mirror.notification_ok(text, text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.mirror_my_notifications()', 'EXECUTE')
    and not has_function_privilege('anon', 'public.mirror_my_notifications_set(jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.mirror_my_notifications_set(jsonb)', 'EXECUTE')
    and not has_table_privilege('authenticated', 'mirror.profiles', 'SELECT');
  r := r || format('6 send check and profiles closed to browsers; anon cannot call the person''s functions: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
