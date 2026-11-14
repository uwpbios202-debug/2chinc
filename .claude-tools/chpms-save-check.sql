do $chk$
declare u uuid := gen_random_uuid(); s uuid := gen_random_uuid(); v uuid; res text; o text;
begin
  insert into auth.users (id, email) values (u, 'check.staffref@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (s, u, now(), now(), now(), 'aal2');
  insert into condo_staff (email, name) values ('check.staffref@example.invalid', 'CHECK STAFF');
  select org_id into o from chpms_orgs where our_relationship <> 'do_not_refer' limit 1;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'email', 'check.staffref@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', s)::text, true);
  begin
    v := public.chpms_referral_save(jsonb_build_object('org_id', o, 'first_name', 'Check', 'last_name', 'Person', 'phone', '414-555-0100', 'consent', true, 'consent_name', 'Check Person'));
    res := 'saved ' || v::text;
  exception when others then res := 'ERROR ' || sqlstate || ': ' || sqlerrm;
  end;
  execute 'reset role';
  raise exception 'MIRROR CHECK RESULTS (all rolled back): %', res;
end $chk$;
