-- Phase N TN.4 check: a match to a home the Navigator runs is marked, and the placement waits for the person's typed confirmation.
-- Fictional Navigators, office staff, home and people (marked sample, so no email); always rolled back.
do $chk$
declare
  r text[] := '{}'; n1 uuid; n2 uuid; ll uuid; u uuid; u2 uuid; rm1 uuid; rm2 uuid; p uuid; q uuid; j jsonb; ok boolean;
  u1 uuid := gen_random_uuid(); uo uuid := gen_random_uuid(); us uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid(); so uuid := gen_random_uuid(); ss uuid := gen_random_uuid(); j1 text; jo text; js text;
begin
  insert into auth.users (id, email) values (u1, 'check.ra@example.invalid'), (uo, 'check.rb@example.invalid'), (us, 'check.rs@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values
    (s1, u1, now(), now(), now(), 'aal1'), (so, uo, now(), now(), now(), 'aal1'), (ss, us, now(), now(), now(), 'aal2');
  j1 := json_build_object('sub', u1, 'email', 'check.ra@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', s1)::text;
  jo := json_build_object('sub', uo, 'email', 'check.rb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', so)::text;
  js := json_build_object('sub', us, 'email', 'check.rs@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', ss)::text;
  insert into condo_staff (email, name) values ('check.rs@example.invalid', 'CHECK RS');
  insert into navigators (name, email, status) values ('CHECK Runner', 'check.ra@example.invalid', 'pilot') returning id into n1;
  insert into navigators (name, email, status) values ('CHECK Other', 'check.rb@example.invalid', 'pilot') returning id into n2;
  insert into nav_landlords (name) values ('CHECK Landlord') returning id into ll;
  insert into nav_units (landlord_id, address, operated_by_navigator, is_sample, status, rent) values (ll, '1 Check St', n1, true, 'occupied', 900) returning id into u;
  insert into nav_units (landlord_id, address, is_sample, status, rent) values (ll, '2 Check St', true, 'reserved', 700) returning id into u2;
  insert into nav_rooms (unit_id, label, monthly_rate, status) values (u, 'Room A', 450, 'reserved') returning id into rm1;
  insert into nav_rooms (unit_id, label, monthly_rate, status) values (u, 'Room B', 450, 'available') returning id into rm2;
  insert into nav_referrals (navigator_id, first_name, last_name, is_sample, consent_name, consent_on, status, nav_unit_id, nav_room_id, unit_rent, contribution_monthly, income_verified_on, matched_at)
    values (n1, 'Check', 'Roomer', true, 'Check Roomer', current_date, 'matched', u, rm1, 450, 450, current_date, now()) returning id into p;
  insert into nav_referrals (navigator_id, first_name, last_name, is_sample, consent_name, consent_on, status, nav_unit_id, unit_rent, contribution_monthly, income_verified_on, matched_at)
    values (n1, 'Check', 'Elsewhere', true, 'Check Elsewhere', current_date, 'matched', u2, 700, 700, current_date, now()) returning id into q;
  perform set_config('role', 'authenticated', true);

  -- 1. marked "a room you run" with the exact words; a match to a home the Navigator does not run is not
  perform set_config('request.jwt.claims', j1, true);
  j := public.nav_own_room_state(p);
  ok := (j ->> 'own_room')::boolean and j -> 'confirmed' = 'null'::jsonb and j ->> 'place' = '1 Check St, Room A'
    and j ->> 'words' like 'I know that my Housing Navigator, CHECK Runner, runs this home (1 Check St, Room A) and rents me the room.%'
    and not (public.nav_own_room_state(q) ->> 'own_room')::boolean;
  r := r || format('1 own-room match marked with the exact words; others not: %s', ok);

  -- 2. the placement waits for the person's confirmation; other homes are not held up
  ok := true;
  begin perform public.nav_referral_step(p, 'approved', '{"note":"check"}'); ok := false; exception when invalid_parameter_value then ok := sqlerrm like 'This is a home the Navigator runs%'; end;
  perform public.nav_referral_step(q, 'approved', '{"note":"check"}');
  execute 'reset role';
  ok := ok and (select status from nav_referrals where id = q) = 'approved';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  r := r || format('2 placement blocked until confirmed; other homes unaffected: %s', ok);

  -- 3. wrong name refused; another Navigator refused; the right name confirms, then the placement goes through
  begin perform public.nav_own_room_confirm(p, 'Somebody Else'); ok := false; exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claims', jo, true);
  begin perform public.nav_own_room_confirm(p, 'Check Roomer'); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', j1, true);
  j := public.nav_own_room_confirm(p, ' check  roomer ');
  ok := ok and j -> 'confirmed' ->> 'name' = 'check  roomer';
  perform public.nav_referral_step(p, 'approved', '{"note":"check"}');
  execute 'reset role';
  ok := ok and (select status from nav_referrals where id = p) = 'approved'
    and exists (select 1 from nav_events where referral_id = p and action = 'own_room_confirmed');
  r := r || format('3 typed full name confirms (logged), then the placement goes through: %s', ok);

  -- 4. a different room needs a new confirmation
  update nav_referrals set status = 'matched', nav_room_id = rm2, approved_at = null where id = p;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', j1, true);
  ok := public.nav_own_room_state(p) -> 'confirmed' = 'null'::jsonb;
  begin perform public.nav_referral_step(p, 'approved', '{"note":"check"}'); ok := false; exception when invalid_parameter_value then null; end;
  r := r || format('4 another room needs a new confirmation: %s', ok);

  -- 5. the office lists these matches; a Navigator cannot
  ok := true;
  begin perform public.nav_own_room_matches(); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', js, true);
  j := public.nav_own_room_matches();
  ok := ok and exists (select 1 from jsonb_array_elements(j) e where e ->> 'id' = p::text and e ->> 'navigator' = 'CHECK Runner')
    and not exists (select 1 from jsonb_array_elements(j) e where e ->> 'id' = q::text);
  r := r || format('5 office lists own-room matches, Navigators cannot: %s', ok);

  -- 6. closed to browsers
  execute 'reset role';
  ok := not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'public' and g.table_name = 'nav_own_room_confirms'
                    and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
    and not has_function_privilege('anon', 'public.nav_own_room_confirm(uuid, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.nav_own_room(public.nav_referrals)', 'execute');
  r := r || format('6 table and helpers closed to browsers: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
