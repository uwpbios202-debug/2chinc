-- Phase 2 finding E check (migration 20261119269700): platform admin is an explicit list; only the 2nd Chance main admin changes it.
-- Fictional people only; always rolled back: sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; owner uuid; ok boolean; j jsonb; n int; n_old int;
  main text := json_build_object('sub', gen_random_uuid(), 'email', 'check.e.main@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  oadm text := json_build_object('sub', gen_random_uuid(), 'email', 'check.e.ownadmin@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  padm text := json_build_object('sub', gen_random_uuid(), 'email', 'check.e.padmin@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into owner from mirror.organizations where is_platform_owner;

  -- 0 the first list is exactly who had the power under the old rule (counted, no emails shown)
  select count(distinct e) into n_old from (
    select lower(email) e from public.portal_admins where email like '%_@_%'
    union select m.auth_email from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id
          where o.is_platform_owner and o.active and m.active and m.role = 'org_admin') s;
  select count(*) into n from mirror.platform_admins where active;
  r := r || format('0 first list = everyone with the power under the old rule (%s, %s): %s', n, n_old, n = n_old and n > 0);

  insert into public.portal_admins (email, name) values ('check.e.main@example.invalid', 'CHECK Main Admin');
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (owner, 'check.e.main@example.invalid', 'CHECK Main Admin', 'org_admin'),
    (owner, 'check.e.ownadmin@example.invalid', 'CHECK Own Admin', 'org_admin'),
    (owner, 'check.e.padmin@example.invalid', 'CHECK Listed Admin', 'coordinator');
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.e.main@example.invalid', 'CHECK Main Admin', 'check');
  perform set_config('role', 'authenticated', true);

  -- 1 an org admin of 2nd Chance who is not on the list: manages 2nd Chance only, no power over other organizations
  perform set_config('request.jwt.claims', oadm, true);
  j := public.mirror_admin_orgs();
  ok := not (j ->> 'platform_admin')::boolean and jsonb_array_length(j -> 'orgs') = 1;
  begin perform public.mirror_admin_org_save(jsonb_build_object('name', 'CHECK E Org', 'kind', 'navigator')); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_platform_admins(); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('1 2nd Chance org admin NOT on the list: no platform power (sees 2nd Chance only, cannot add organizations): %s', ok);

  -- 2 the main admin: is a platform admin, can add a 2nd Chance member to the list (logged); refused for a non-member
  perform set_config('request.jwt.claims', main, true);
  ok := (public.mirror_admin_orgs() ->> 'platform_admin')::boolean and (public.mirror_platform_admins() ->> 'can_edit')::boolean;
  begin perform public.mirror_platform_admin_save(jsonb_build_object('email', 'check.e.stranger@example.invalid')); ok := false; exception when invalid_parameter_value then null; end;
  j := public.mirror_platform_admin_save(jsonb_build_object('email', 'CHECK.E.PAdmin@example.invalid'));
  select x into j from jsonb_array_elements(j -> 'admins') x where x ->> 'email' = 'check.e.padmin@example.invalid';
  ok := ok and (j ->> 'active')::boolean and j ->> 'added_by' = 'CHECK Main Admin' and j ->> 'name' = 'CHECK Listed Admin';
  r := r || format('2 main admin adds a 2nd Chance member to the list (by name, any case of email); a non-member is refused: %s', ok);

  -- 3 the listed admin now has platform power, can see the list, but cannot change it
  perform set_config('request.jwt.claims', padm, true);
  ok := (public.mirror_admin_orgs() ->> 'platform_admin')::boolean and not (public.mirror_platform_admins() ->> 'can_edit')::boolean;
  begin perform public.mirror_platform_admin_save(jsonb_build_object('email', 'check.e.ownadmin@example.invalid')); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('3 listed admin has platform power and sees the list, but only the main admin can change it: %s', ok);

  -- 4 leaving 2nd Chance (member made inactive) ends platform power at once, list row or not
  execute 'reset role';
  update mirror.organization_members set active = false where organization_id = owner and auth_email = 'check.e.padmin@example.invalid';
  perform set_config('role', 'authenticated', true);
  begin perform public.mirror_platform_admins(); ok := false; exception when insufficient_privilege then ok := true; end;
  r := r || format('4 listed admin who left 2nd Chance has no platform power: %s', ok);

  -- 5 the main admin removes them (logged); the main admin cannot remove themself (nobody would be left to change the list)
  perform set_config('request.jwt.claims', main, true);
  j := public.mirror_platform_admin_save(jsonb_build_object('email', 'check.e.padmin@example.invalid', 'active', false));
  select x into j from jsonb_array_elements(j -> 'admins') x where x ->> 'email' = 'check.e.padmin@example.invalid';
  ok := not (j ->> 'active')::boolean and j ->> 'removed_by' = 'CHECK Main Admin';
  begin perform public.mirror_platform_admin_save(jsonb_build_object('email', 'check.e.main@example.invalid', 'active', false)); ok := false; exception when invalid_parameter_value then ok := ok and sqlerrm like '%yourself%'; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where action in ('platform_admin_add', 'platform_admin_remove') and row_id = 'check.e.padmin@example.invalid';
  r := r || format('5 removal works and is shown; the main admin cannot remove themself; add + remove logged (%s, 2): %s', n, ok and n = 2);

  -- 6 nobody reaches the table directly
  ok := not has_table_privilege('authenticated', 'mirror.platform_admins', 'select') and not has_table_privilege('anon', 'mirror.platform_admins', 'select');
  r := r || format('6 no direct access to the list for signed-in or anonymous users: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
