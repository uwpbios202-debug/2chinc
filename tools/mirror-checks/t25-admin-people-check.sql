-- Mirror T2.5/T2.6 check: who may manage organizations, members and people. Fictional people only; always rolled back.
-- Run with the migration via .claude-tools/mirror-rollback-check.sh.
do $chk$
declare
  r text[] := '{}';
  owner uuid; nav uuid; p1 uuid; p2 uuid; mid uuid;
  j jsonb; n int; ok boolean;
begin
  select id into owner from mirror.organizations where is_platform_owner;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (owner, 'check.padmin@example.invalid', 'CHECK Platform Admin', 'org_admin'),
    (owner, 'check.owner.coord@example.invalid', 'CHECK Owner Coordinator', 'coordinator');
  -- since migration 20261119269700 (finding E) platform admin is an explicit list, not "org admin of 2nd Chance"
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.padmin@example.invalid', 'CHECK Platform Admin', 'check');

  -- 1. a stranger and a no-authenticator admin are refused
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.stranger@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  begin perform public.mirror_admin_orgs(); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.padmin@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  begin perform public.mirror_admin_orgs(); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('1 stranger and admin without authenticator refused: %s', ok);

  -- 2. platform admin (org_admin of 2nd Chance, aal2): sees orgs, creates a Navigator business, adds its admin and a coordinator
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.padmin@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := public.mirror_admin_orgs();
  ok := (j ->> 'platform_admin')::boolean and jsonb_array_length(j -> 'orgs') >= 1;
  nav := public.mirror_admin_org_save(jsonb_build_object('name', 'CHECK Navigator Co', 'kind', 'navigator'));
  perform public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'CHECK.Nav.Admin@example.invalid', 'name', 'CHECK Nav Admin', 'role', 'org_admin'));
  perform public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'check.nav.coord@example.invalid', 'name', 'CHECK Nav Coordinator', 'role', 'coordinator'));
  ok := ok and jsonb_array_length(public.mirror_admin_members(nav)) = 2;
  begin perform public.mirror_admin_org_save(jsonb_build_object('id', owner, 'name', '2nd Chance Housing Inc', 'active', false)); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('2 platform admin: lists orgs, creates an organization, adds members, cannot close 2nd Chance: %s', ok);

  -- 3. the Navigator business admin: sees only their own org, cannot create orgs, cannot touch 2nd Chance members, cannot remove the last admin
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.nav.admin@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := public.mirror_admin_orgs();
  ok := not (j ->> 'platform_admin')::boolean and jsonb_array_length(j -> 'orgs') = 1 and j -> 'orgs' -> 0 ->> 'name' = 'CHECK Navigator Co';
  begin perform public.mirror_admin_org_save(jsonb_build_object('name', 'CHECK Sneaky Org')); ok := ok and false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_admin_members(owner); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select id into mid from mirror.organization_members where organization_id = nav and auth_email = 'check.nav.admin@example.invalid';
  perform set_config('role', 'authenticated', true);
  begin perform public.mirror_admin_member_save(jsonb_build_object('id', mid, 'name', 'CHECK Nav Admin', 'role', 'coordinator')); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('3 Navigator business admin: own org only, no new orgs, no 2nd Chance members, last admin kept: %s', ok);

  -- 4. the Navigator coordinator adds people: with email = invited, without = active; coordinator email refused
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.nav.coord@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  p1 := public.mirror_person_add(jsonb_build_object('organization_id', nav, 'preferred_name', 'CHECK Pat', 'email', 'check.pat@example.invalid', 'birth_year', '1988'));
  p2 := public.mirror_person_add(jsonb_build_object('organization_id', nav, 'preferred_name', 'CHECK Sam'));
  j := public.mirror_people(nav);
  ok := jsonb_array_length(j) = 2
    and (select x ->> 'status' from jsonb_array_elements(j) x where x ->> 'id' = p1::text) = 'invited'
    and (select x ->> 'status' from jsonb_array_elements(j) x where x ->> 'id' = p2::text) = 'active';
  begin perform public.mirror_person_add(jsonb_build_object('organization_id', nav, 'preferred_name', 'X', 'email', 'check.owner.coord@example.invalid')); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_add(jsonb_build_object('organization_id', nav, 'preferred_name', 'CHECK Pat again', 'email', 'check.pat@example.invalid')); ok := ok and false; exception when unique_violation then null; end;
  perform public.mirror_person_status(nav, p2, 'ended');
  ok := ok and (select x ->> 'status' from jsonb_array_elements(public.mirror_people(nav)) x where x ->> 'id' = p2::text) = 'ended';
  begin perform public.mirror_people(owner); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('4 coordinator: adds people (invited / active), no coordinator emails, no duplicates, ends work, cannot list 2nd Chance people: %s', ok);

  -- 5. 2nd Chance's coordinator cannot see the Navigator's people; the person they added can still sign in (switch on) only while linked
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.owner.coord@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  begin perform public.mirror_people(nav); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.mirror_person_status(nav, p1, 'ended'); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('5 other organizations cannot list or change these people: %s', ok);

  -- 6. audit rows written; browsers cannot reach the helpers; anon cannot call the functions
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where organization_id = nav;
  ok := n >= 6 and not has_function_privilege('anon', 'public.mirror_people(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'mirror.is_platform_admin()', 'execute');
  r := r || format('6 audit rows for the Navigator org: %s; helpers closed to browsers and anon: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
