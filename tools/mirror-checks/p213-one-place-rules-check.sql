-- Mirror P2-13 check: one place for the access rules (D-41). The same powers as before for each role, and the rules table now decides:
-- taking a row out of mirror.role_permissions takes the power away, adding one gives it. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/p213-one-place-rules-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; ok boolean; nh uuid; n int;
  ua uuid := gen_random_uuid(); uo uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uv uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); so uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sv uuid := gen_random_uuid();
  pa text; ox text; cx text; vx text;
begin
  insert into auth.users (id, email) values (ua, 'check.q.a@example.invalid'), (uo, 'check.q.ox@example.invalid'), (uc, 'check.q.cx@example.invalid'), (uv, 'check.q.vx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
  values (sa, ua, now(), now(), now()), (so, uo, now(), now(), now()), (sc, uc, now(), now(), now()), (sv, uv, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.q.a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  ox := json_build_object('sub', uo, 'email', 'check.q.ox@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', so)::text;
  cx := json_build_object('sub', uc, 'email', 'check.q.cx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  vx := json_build_object('sub', uv, 'email', 'check.q.vx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sv)::text;
  insert into mirror.organizations (name, kind) values ('CHECK Q X', 'nonprofit') returning id into x;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.q.a@example.invalid', 'CHECK Q A', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.q.ox@example.invalid', 'CHECK Q OX', 'org_admin'), (x, 'check.q.cx@example.invalid', 'CHECK Q CX', 'coordinator'),
    (x, 'check.q.vx@example.invalid', 'CHECK Q VX', 'volunteer');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');

  -- 1. no permission decision names a role in code any more (only labels and identities remain)
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname in ('mirror', 'public') and (p.proname like 'mirror%' or s.nspname = 'mirror')
     and (pg_get_functiondef(p.oid) like '%in (''coordinator'', ''org_admin'')%' or pg_get_functiondef(p.oid) like '%in (''org_admin'', ''coordinator'')%'
          or pg_get_functiondef(p.oid) like '%my_role(%) = ''org_admin''%' or pg_get_functiondef(p.oid) like '%my_role(%), '''') <> ''org_admin'' then%'
          or pg_get_functiondef(p.oid) like '%my_role(%), '''') = ''org_admin''%');
  r := r || format('1 no function decides a permission by naming a role in code (%s found): %s', n, n = 0);

  -- 2. the same powers as before: admin manages and reads the audit log; coordinator works with people and confirms; volunteer neither
  perform set_config('request.jwt.claims', ox, true);
  ok := mirror.coordinates(x) and mirror.can_manage_members(x) and (public.mirror_services(x) ->> 'can_manage')::boolean;
  perform public.mirror_org_audit(x, null, null);
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and mirror.coordinates(x) and not mirror.can_manage_members(x) and not (public.mirror_services(x) ->> 'can_manage')::boolean;
  begin perform public.mirror_org_audit(x, null, null); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', vx, true);
  ok := ok and not mirror.coordinates(x) and not mirror.can_manage_members(x);
  r := r || format('2 same powers as before (admin, coordinator, volunteer): %s', ok);

  -- 3. the table decides: without the coordinator's "workspace" row the coordinator is out; without "confirm" a need can't be confirmed
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  nh := (public.mirror_need_save(null, 'housing', 'CHECK bed', null, 'soon') ->> 'id')::uuid;
  perform public.mirror_need_status(nh, 'obtained', null);
  delete from mirror.role_permissions where role = 'coordinator' and category in ('workspace', 'confirm');
  perform set_config('request.jwt.claims', cx, true);
  ok := not mirror.coordinates(x);
  begin perform public.mirror_workspace_dashboard(x); ok := false; exception when others then null; end;
  begin perform public.mirror_need_status(nh, 'verified', null); ok := false; exception when others then null; end;
  r := r || format('3 rows taken out of the table: the coordinator loses the workspace and confirming: %s', ok);

  -- 4. ...and adding "organization edit" to the coordinator lets them manage services and members
  insert into mirror.role_permissions (role, category, action) values ('coordinator', 'organization', 'edit'), ('coordinator', 'confirm', 'edit'), ('coordinator', 'workspace', 'view');
  ok := mirror.can_manage_members(x) and public.mirror_service_save(jsonb_build_object('organization_id', x, 'name', 'CHECK Q svc')) ? 'id'
    and public.mirror_need_status(nh, 'verified', null) ->> 'status' = 'verified';
  r := r || format('4 rows added to the table: the coordinator may manage members and services and confirm again: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
