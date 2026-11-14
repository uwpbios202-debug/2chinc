-- Mirror P2-08 check: platform admin pages (D-40). Only 2nd Chance platform admins (on the list, member of 2nd Chance, authenticator);
-- counts and rules only, no person named, no emails; deletion requests by date and code; the platform audit log names members, never a
-- person (a short code instead) and can be narrowed to one organization; both reads are logged. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/p208-platform-admin-pages-check.sql
do $chk$
declare
  r text[] := '{}'; owner uuid; y uuid; a uuid; j jsonb; e jsonb; ok boolean; n0 int; n1 int; total int; code text;
  up uuid := gen_random_uuid(); uo uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sp uuid := gen_random_uuid(); so uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pl text; pl1 text; oa text; cy text;
begin
  insert into auth.users (id, email) values (up, 'check.p8.plat@example.invalid'), (uo, 'check.p8.oadm@example.invalid'), (uy, 'check.p8.cy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sp, up, now(), now(), now()), (so, uo, now(), now(), now()), (sy, uy, now(), now(), now());
  pl := json_build_object('sub', up, 'email', 'check.p8.plat@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sp)::text;
  pl1 := json_build_object('sub', up, 'email', 'check.p8.plat@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sp)::text;
  oa := json_build_object('sub', uo, 'email', 'check.p8.oadm@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', so)::text;
  cy := json_build_object('sub', uy, 'email', 'check.p8.cy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  select id into owner from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK P8 Y', 'nonprofit') returning id into y;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (owner, 'check.p8.plat@example.invalid', 'CHECK P8 Platform', 'org_admin'), (owner, 'check.p8.oadm@example.invalid', 'CHECK P8 OwnAdmin', 'org_admin'),
    (y, 'check.p8.cy@example.invalid', 'CHECK P8 CY', 'coordinator');
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.p8.plat@example.invalid', 'CHECK P8 Platform', 'check');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, deletion_requested_at)
  values ('check.p8.person@example.invalid', 'CHECKNAME P8', y, now() - interval '5 days') returning id into a;
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (y, a, 'active');
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, individual_id, action, category, table_name)
  values ('check.p8.cy@example.invalid', 'coordinator', y, a, 'view', 'general', 'needs');
  select count(*) into total from mirror.individuals;
  code := left(md5(a::text), 6);
  select count(*) into n0 from mirror.audit_logs where actor_role = 'platform_admin' and table_name in ('platform_overview', 'audit_logs');
  perform set_config('role', 'authenticated', true);

  -- 1. the platform admin: the overview counts everyone, lists the deletion request by code and dates, and holds no name and no email
  perform set_config('request.jwt.claims', pl, true);
  j := public.mirror_platform_overview();
  select v into e from jsonb_array_elements(j -> 'deletions') v where v ->> 'code' = code;
  ok := (j -> 'people' ->> 'total')::int = total and e is not null and (e ->> 'due_on')::date = (e ->> 'requested_on')::date + 30
    and position('CHECKNAME' in j::text) = 0 and position('@' in j::text) = 0
    and jsonb_array_length(j -> 'roles') > 0 and exists (select 1 from jsonb_array_elements(j -> 'organizations') v where v ->> 'name' = 'CHECK P8 Y');
  r := r || format('1 overview: everyone counted, deletion request by code and dates (due 30 days later), roles listed, no name, no email: %s', ok);

  -- 2. the platform audit: the coordinator by name, the person only by code, never the name or an email; narrowed to one organization
  j := public.mirror_platform_audit(y, null);
  select v into e from jsonb_array_elements(j -> 'rows') v where v ->> 'what' = 'needs';
  ok := e ->> 'who' = 'CHECK P8 CY' and e ->> 'person' = 'Person ' || code and e ->> 'organization' = 'CHECK P8 Y'
    and position('CHECKNAME' in j::text) = 0 and position('@' in j::text) = 0
    and not exists (select 1 from jsonb_array_elements(j -> 'rows') v where v ->> 'organization' is distinct from 'CHECK P8 Y');
  r := r || format('2 platform audit: member by name, person by code only, no email, one organization only when asked: %s', ok);

  -- 3. both reads are in the audit log
  execute 'reset role';
  select count(*) into n1 from mirror.audit_logs where actor_role = 'platform_admin' and table_name in ('platform_overview', 'audit_logs');
  perform set_config('role', 'authenticated', true);
  ok := n1 = n0 + 2;
  r := r || format('3 both reads logged (%s new): %s', n1 - n0, ok);

  -- 4. refused: the same admin without the authenticator; a 2nd Chance org admin not on the list; another organization's coordinator
  ok := true;
  perform set_config('request.jwt.claims', pl1, true);
  begin perform public.mirror_platform_overview(); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', oa, true);
  begin perform public.mirror_platform_overview(); ok := false; exception when others then null; end;
  begin perform public.mirror_platform_audit(null, null); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', cy, true);
  begin perform public.mirror_platform_audit(y, null); ok := false; exception when others then null; end;
  r := r || format('4 refused without the authenticator, for a 2nd Chance admin not on the list, for another organization: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
