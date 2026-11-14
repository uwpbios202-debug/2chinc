-- Phase 2 fix 4 check (migration 20261119268000): a 2nd Chance (platform) admin cannot join another organization unseen.
-- Fictional people only; always rolled back: sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; owner uuid; nav uuid; cid uuid; selfid uuid; j jsonb; m jsonb; ok boolean;
  pad text := json_build_object('sub', gen_random_uuid(), 'email', 'check.padmin4@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  nad text := json_build_object('sub', gen_random_uuid(), 'email', 'check.nav4.admin@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into owner from mirror.organizations where is_platform_owner;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (owner, 'check.padmin4@example.invalid', 'CHECK Platform Admin', 'org_admin');
  -- since migration 20261119269700 (finding E) platform admin is an explicit list, not "org admin of 2nd Chance"
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.padmin4@example.invalid', 'CHECK Platform Admin', 'check');
  perform set_config('role', 'authenticated', true);

  -- platform admin sets up a Navigator business and its first admin (still allowed, and marked)
  perform set_config('request.jwt.claims', pad, true);
  nav := public.mirror_admin_org_save(jsonb_build_object('name', 'CHECK Nav Four', 'kind', 'navigator'));
  perform public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'check.nav4.admin@example.invalid', 'name', 'CHECK Nav4 Admin', 'role', 'org_admin'));

  -- 1 the platform admin cannot add themselves to that organization, as admin or coordinator
  ok := true;
  begin perform public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'check.padmin4@example.invalid', 'name', 'Me', 'role', 'org_admin')); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'CHECK.PAdmin4@example.invalid', 'name', 'Me', 'role', 'coordinator')); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('1 platform admin adding themselves to another organization (any case of email) refused: %s', ok);

  -- 2 the organization's own admin adds a coordinator; the platform admin cannot change that member's email to their own
  perform set_config('request.jwt.claims', nad, true);
  cid := public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'check.nav4.coord@example.invalid', 'name', 'CHECK Nav4 Coord', 'role', 'coordinator'));
  perform set_config('request.jwt.claims', pad, true);
  begin perform public.mirror_admin_member_save(jsonb_build_object('id', cid, 'email', 'check.padmin4@example.invalid', 'name', 'CHECK Nav4 Coord', 'role', 'coordinator')); ok := false; exception when insufficient_privilege then ok := true; end;
  r := r || format('2 platform admin taking over a member by changing the email to their own refused: %s', ok);

  -- 3 the organization adds the platform admin as coordinator; they cannot promote themselves to admin there
  perform set_config('request.jwt.claims', nad, true);
  selfid := public.mirror_admin_member_save(jsonb_build_object('organization_id', nav, 'email', 'check.padmin4@example.invalid', 'name', 'CHECK Platform Admin', 'role', 'coordinator'));
  perform set_config('request.jwt.claims', pad, true);
  begin perform public.mirror_admin_member_save(jsonb_build_object('id', selfid, 'name', 'CHECK Platform Admin', 'role', 'org_admin')); ok := false; exception when insufficient_privilege then ok := true; end;
  r := r || format('3 platform admin promoting themselves inside another organization refused: %s', ok);

  -- 4 the organization's admin sees which members 2nd Chance added or changed, by name; its own additions are not marked
  perform set_config('request.jwt.claims', pad, true);
  perform public.mirror_admin_member_save(jsonb_build_object('id', cid, 'name', 'CHECK Nav4 Coord', 'role', 'volunteer'));
  perform set_config('request.jwt.claims', nad, true);
  j := public.mirror_admin_members(nav);
  select x into m from jsonb_array_elements(j) x where x ->> 'email' = 'check.nav4.admin@example.invalid';
  ok := m ->> 'platform_changed_by' = 'CHECK Platform Admin' and m ->> 'platform_changed_at' is not null;
  select x into m from jsonb_array_elements(j) x where x ->> 'email' = 'check.nav4.coord@example.invalid';
  ok := ok and m ->> 'platform_changed_by' = 'CHECK Platform Admin' and m ->> 'role' = 'volunteer';
  select x into m from jsonb_array_elements(j) x where x ->> 'email' = 'check.padmin4@example.invalid';
  ok := ok and m ->> 'platform_changed_at' is null;
  r := r || format('4 the organization sees "changed by CHECK Platform Admin (2nd Chance)" on what 2nd Chance did, not on its own changes: %s', ok);

  -- 5 inside 2nd Chance itself the platform admin is that organization's own admin: nothing is marked
  perform set_config('request.jwt.claims', pad, true);
  perform public.mirror_admin_member_save(jsonb_build_object('organization_id', owner, 'email', 'check.owner4.coord@example.invalid', 'name', 'CHECK Owner4 Coord', 'role', 'coordinator'));
  select x into m from jsonb_array_elements(public.mirror_admin_members(owner)) x where x ->> 'email' = 'check.owner4.coord@example.invalid';
  r := r || format('5 changes inside 2nd Chance by its own admin are not marked: %s', m ->> 'platform_changed_at' is null);
  execute 'reset role';
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
