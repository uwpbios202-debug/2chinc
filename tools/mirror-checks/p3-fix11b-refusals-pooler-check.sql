-- Check for P3-11 follow-up (migration 20261119285000). Fictional people only; always rolled back. The second connection is real
-- (the pooler), but it is only asked things that cannot add a row: a person who does not exist, a wrong reason, a read it may not do.
-- sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; ok boolean; pw text; b boolean; x uuid; p uuid; j jsonb; n int; e text;
  cc text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p311b@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1 dblink is in the private schema; nobody but postgres can use it; the second connection opens
  ok := (select extnamespace::regnamespace::text from pg_extension where extname = 'dblink') = 'mirror_link'
    and not has_schema_privilege('anon', 'mirror_link', 'USAGE') and not has_schema_privilege('authenticated', 'mirror_link', 'USAGE')
    and not has_schema_privilege('service_role', 'mirror_link', 'USAGE')
    and mirror.refusal_channel_ok() = 'ok';
  r := r || format('1 dblink private (mirror_link), no USAGE for anon/authenticated/service_role; channel: %s; %s', mirror.refusal_channel_ok(), ok);

  -- 2 through the real second connection: unknown person and a non-refusal reason add nothing
  select decrypted_secret into pw from vault.decrypted_secrets where name = 'mirror_refusal_writer_password';
  select t.v into b from mirror_link.dblink(mirror.refusal_conninfo(pw),
    format('select mirror.audit_refusal_write(%L, %L::uuid, null, %L, %L, %L, %L, %L)', 'a@example.invalid', gen_random_uuid(), 'coordinator', 'health', 't', 'r', 'no_consent')) as t(v boolean);
  ok := not b;
  select t.v into b from mirror_link.dblink(mirror.refusal_conninfo(pw),
    format('select mirror.audit_refusal_write(%L, %L::uuid, null, %L, %L, %L, %L, %L)', 'a@example.invalid', gen_random_uuid(), 'coordinator', 'health', 't', 'r', 'edit')) as t(v boolean);
  ok := ok and not b;
  r := r || format('2 writer reaches its function over the pooler; unknown person / wrong reason add nothing: %s', ok);

  -- 3 the writer cannot read the log or anything else
  begin
    perform t.v from mirror_link.dblink(mirror.refusal_conninfo(pw), 'select count(*)::int from mirror.audit_logs') as t(v int);
    e := 'read allowed';
  exception when others then e := case when sqlerrm ilike '%permission denied%' then 'refused' else replace(sqlerrm, pw, '***') end;
  end;
  begin
    perform t.v from mirror_link.dblink(mirror.refusal_conninfo(pw), 'select count(*)::int from mirror.individuals') as t(v int);
    e := e || ', individuals read allowed';
  exception when others then e := e || case when sqlerrm ilike '%permission denied%' then ', refused' else ', ' || replace(sqlerrm, pw, '***') end;
  end;
  r := r || format('3 writer reading the log and the people: %s', e);

  -- 4 a refusal for a made-up person (not visible to the second connection) is logged exactly once here (fallback)
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p311bp@example.invalid', 'CHECK Person') returning id into p;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.p311b@example.invalid', 'CHECK Coordinator', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, p, 'active');
  perform set_config('request.jwt.claims', cc, true);
  j := mirror.allowed(p, 'health', 'view', null, 'assessment_responses', 'q1');
  select count(*) into n from mirror.audit_logs where individual_id = p and action = 'refused' and reason = 'no_consent';
  r := r || format('4 refused (%s) and logged once by the fallback: %s', not (j ->> 'ok')::boolean, n = 1);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
