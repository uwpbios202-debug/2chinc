-- Check for P3-11 (migration 20261119284000), BEFORE it is applied. Fictional people only; always rolled back.
-- The second connection cannot see the new role or the made-up people inside this transaction, so every refusal here takes the
-- fallback (logged in this transaction, as before). The live second connection is checked after applying with
-- select mirror.refusal_channel_ok() (read-only: "select 1").
-- The gate is called as the database owner with the made-up sign-in claims (authenticated cannot use schema mirror).
-- sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; ok boolean; x uuid; p uuid; j jsonb; n0 int; n1 int;
  cc text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p311c@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  c1 text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p311c@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1 rights: the writer can only call the write function; browsers cannot reach dblink or the new functions
  ok := has_function_privilege('mirror_refusal_writer', 'mirror.audit_refusal_write(text, uuid, uuid, text, text, text, text, text)', 'EXECUTE')
    and not has_function_privilege('mirror_refusal_writer', 'mirror.audit_refused(uuid, uuid, text, text, text, text, text)', 'EXECUTE')
    and not has_function_privilege('mirror_refusal_writer', 'mirror.refusal_channel_ok()', 'EXECUTE')
    and not has_table_privilege('mirror_refusal_writer', 'mirror.audit_logs', 'SELECT')
    and not has_table_privilege('mirror_refusal_writer', 'mirror.audit_logs', 'INSERT')
    and not has_table_privilege('mirror_refusal_writer', 'mirror.individuals', 'SELECT')
    and not has_function_privilege('authenticated', 'mirror.audit_refusal_write(text, uuid, uuid, text, text, text, text, text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'mirror.audit_refused(uuid, uuid, text, text, text, text, text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'mirror.refusal_channel_ok()', 'EXECUTE')
    and not exists (select 1 from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
                    where ns.nspname = 'extensions' and pr.proname like 'dblink%'
                      and (has_function_privilege('authenticated', pr.oid, 'EXECUTE') or has_function_privilege('anon', pr.oid, 'EXECUTE')))
    and (select rolconnlimit from pg_roles where rolname = 'mirror_refusal_writer') = 3
    and not (select rolinherit or rolsuper or rolcreaterole or rolcreatedb from pg_roles where rolname = 'mirror_refusal_writer')
    and exists (select 1 from vault.secrets where name = 'mirror_refusal_writer_password');
  r := r || format('1 writer can only call the write function; no reading; browsers cannot reach dblink or the new functions; secret in Vault: %s', ok);

  -- 2 the write function refuses a person who does not exist and a reason that is not a refusal reason (adds nothing)
  ok := not mirror.audit_refusal_write('a@example.invalid', gen_random_uuid(), null, 'coordinator', 'health', 't', 'r', 'no_consent');
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p311@example.invalid', 'CHECK Person') returning id into p;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.p311c@example.invalid', 'CHECK Coordinator', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, p, 'active');
  select count(*) into n0 from mirror.audit_logs where individual_id = p;
  ok := ok and not mirror.audit_refusal_write('a@example.invalid', p, x, 'coordinator', 'health', 't', 'r', 'edit');
  select count(*) into n1 from mirror.audit_logs where individual_id = p;
  r := r || format('2 write function: unknown person and non-refusal reason add nothing: %s', ok and n1 = n0);

  -- 3 a refusal with no consent: logged exactly once (fallback here), with who, organization, topic and reason
    perform set_config('request.jwt.claims', cc, true);
  j := mirror.allowed(p, 'health', 'view', null, 'assessment_responses', 'q1');
  ok := not (j ->> 'ok')::boolean
    and (select count(*) from mirror.audit_logs where individual_id = p and action = 'refused') = 1
    and exists (select 1 from mirror.audit_logs where individual_id = p and action = 'refused' and reason = 'no_consent'
                and actor_email = 'check.p311c@example.invalid' and organization_id = x and category = 'health' and actor_role = 'coordinator');
  r := r || format('3 no-consent refusal logged once with who/org/topic/reason: %s', ok);

  -- 4 no authenticator: refused and logged once more (2 in total)
    perform set_config('request.jwt.claims', c1, true);
  j := mirror.allowed(p, 'general', 'view', null, 'assessment_responses', 'q2');
  ok := not (j ->> 'ok')::boolean
    and (select count(*) from mirror.audit_logs where individual_id = p and action = 'refused') = 2
    and exists (select 1 from mirror.audit_logs where individual_id = p and action = 'refused' and reason = 'no_authenticator');
  r := r || format('4 no-authenticator refusal logged once: %s', ok);

  -- 5 allowed and quiet paths unchanged: general view allowed and not logged; a probe never logs
    perform set_config('request.jwt.claims', cc, true);
  ok := (mirror.allowed(p, 'general', 'view', null, 'assessment_responses', 'q3') ->> 'ok')::boolean
    and not mirror.may(p, 'health', 'view');
  ok := ok and (select count(*) from mirror.audit_logs where individual_id = p) = 2;
  r := r || format('5 allowed general view not logged; probe of a refused topic not logged: %s', ok);

  -- 6 "Who looked" shows the refusals to the person
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
