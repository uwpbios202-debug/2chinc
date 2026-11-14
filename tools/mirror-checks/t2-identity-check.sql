-- Mirror Phase 2 checks (SECURITY_PLAN.md section 4, checks 1-5 plus extras). D-01: read-only in effect, fictional people.
-- Run AFTER the migration text in the same transaction (.claude-tools/mirror-rollback-check.sh does both). It always ends by
-- raising 'MIRROR CHECK RESULTS', which rolls back everything (migration, fictional people, audit rows): nothing is kept.
do $chk$
declare
  r text[] := '{}';
  x uuid; y uuid; a uuid; b uuid; cid uuid;
  j jsonb; n int; ok boolean;
begin
  -- setup (as the migration owner): org X = 2nd Chance (seeded), org Y = a fictional Navigator business
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK Fictional Navigator Co', 'navigator') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.person.a@example.invalid', 'CHECK A') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.person.b@example.invalid', 'CHECK B') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.coord.x@example.invalid', 'CHECK Coordinator X', 'coordinator'),
    (y, 'check.coord.y@example.invalid', 'CHECK Coordinator Y', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active'), (y, b, 'active');

  -- 1. anon and authenticated cannot read any mirror table, have no schema usage, and hold no grants
  perform set_config('role', 'authenticated', true);
  begin perform count(*) from mirror.individuals; ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('role', 'anon', true);
  begin perform count(*) from mirror.consents; ok := ok and false; exception when insufficient_privilege then ok := ok and true; end;
  execute 'reset role';
  select count(*) into n from information_schema.role_table_grants where table_schema = 'mirror' and grantee in ('anon', 'authenticated', 'PUBLIC');
  ok := ok and n = 0 and not has_schema_privilege('authenticated', 'mirror', 'usage') and not has_schema_privilege('anon', 'mirror', 'usage');
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'mirror' and c.relkind = 'r' and not c.relrowsecurity;
  ok := ok and n = 0;
  r := r || format('1 closed to anon/authenticated, row security on all: %s', ok);

  -- 2. the person sees their own, not someone else's
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.person.a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := mirror.allowed(a, 'health', 'edit');
  ok := (j->>'ok')::boolean and j->>'role' = 'self';
  j := mirror.allowed(b, 'general', 'view');
  r := r || format('2 person A: own health edit allowed, B general refused: %s', ok and not (j->>'ok')::boolean);

  -- 3. coordinator of X: A (enrolled with X) allowed for general; B (only with Y) refused; no authenticator = refused
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.coord.x@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  ok := (mirror.allowed(a, 'general', 'view')->>'ok')::boolean;
  ok := ok and not (mirror.allowed(b, 'general', 'view')->>'ok')::boolean;
  ok := ok and not (mirror.allowed(a, 'general', 'edit')->>'ok')::boolean;          -- general edit needs consent
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.coord.x@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := mirror.allowed(a, 'general', 'view');
  r := r || format('3 org isolation (A yes, B no, edit needs consent, aal1 refused): %s', ok and not (j->>'ok')::boolean);

  -- 4. consent: health refused, then allowed with consent, edit still refused (view consent), refused again after revoke
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.coord.x@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  ok := not (mirror.allowed(a, 'health', 'view')->>'ok')::boolean;
  ok := ok and (mirror.allowed(a, 'safety_flag', 'view')->>'ok')::boolean;            -- the flag without detail, no consent
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (a, x, 'health', 'view', 'check.person.a@example.invalid') returning id into cid;
  ok := ok and (mirror.allowed(a, 'health', 'view')->>'ok')::boolean;
  ok := ok and not (mirror.allowed(a, 'health', 'edit')->>'ok')::boolean;
  ok := ok and not (mirror.allowed(a, 'mental_health', 'view')->>'ok')::boolean;      -- consent is per category
  update mirror.consents set revoked_at = now(), revoked_by = 'check.person.a@example.invalid' where id = cid;
  ok := ok and not (mirror.allowed(a, 'health', 'view')->>'ok')::boolean;
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by, expires_on) values (a, x, 'legal', 'edit', 'check.person.a@example.invalid', current_date - 1);
  ok := ok and not (mirror.allowed(a, 'legal', 'view')->>'ok')::boolean;              -- expired consent
  r := r || format('4 consent per category, view vs edit, revoke, expiry: %s', ok);

  -- 5. audit rows: coordinator's sensitive views/refusals logged, general views not, the person's own access never
  select count(*) into n from mirror.audit_logs where individual_id = a and actor_email = 'check.coord.x@example.invalid';
  -- expected for A by coord X: general edit refused (1), aal1 refused (1), health refused (1), health view ok (1),
  -- health edit refused (1), mental_health refused (1), health refused after revoke (1), legal refused (1) = 8
  ok := n = 8;
  select count(*) into n from mirror.audit_logs where individual_id = a and action = 'view' and category = 'health';
  ok := ok and n = 1;
  select count(*) into n from mirror.audit_logs where actor_email = 'check.person.a@example.invalid';
  ok := ok and n = 0;
  select count(*) into n from mirror.audit_logs where individual_id = a and reason = 'no_authenticator';
  ok := ok and n = 1;
  r := r || format('5 audit rows as expected (8 for A by coordinator X, none for the person): %s', ok);

  -- 6. the person's "who looked" lists coordinator X; the coordinator gets an empty list
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.person.a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.mirror_who_looked();
  execute 'reset role';
  ok := jsonb_array_length(j) = 8 and j->0->>'who' = 'CHECK Coordinator X';
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.coord.x@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  ok := ok and jsonb_array_length(public.mirror_who_looked()) = 0;
  r := r || format('6 who looked: person sees 8 rows by coordinator X, coordinator sees none: %s', ok);

  -- 7. View as is refused (no session id = view-as session) and logged
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.person.a@example.invalid', 'aal', 'aal2', 'role', 'authenticated')::text, true);
  j := mirror.allowed(a, 'general', 'view');
  select count(*) into n from mirror.audit_logs where individual_id = a and reason = 'view_as';
  r := r || format('7 View as refused and logged: %s', not (j->>'ok')::boolean and n = 1);

  -- 8. the audit log cannot be changed
  begin update mirror.audit_logs set reason = 'x' where individual_id = a; ok := false; exception when insufficient_privilege then ok := true; end;
  begin delete from mirror.audit_logs where individual_id = a; ok := ok and false; exception when insufficient_privilege then ok := ok and true; end;
  r := r || format('8 audit log append-only: %s', ok);

  -- 9. the seed: one platform owner organization, matrix rows
  select count(*) into n from mirror.role_permissions;
  r := r || format('9 seed: owner org %s, matrix rows %s', (select name from mirror.organizations where is_platform_owner), n);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
