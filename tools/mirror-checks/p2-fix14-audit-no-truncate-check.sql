-- Check for Phase 2 fix 14 (migration 20261119266000). Runs after the migration in ONE transaction that always ends in an error,
-- so nothing is kept: sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
do $chk$
declare r text[] := '{}'; ok boolean; n int;
begin
  -- 1 service_role no longer holds TRUNCATE; anon and authenticated still hold nothing on the table
  ok := not has_table_privilege('service_role', 'mirror.audit_logs', 'TRUNCATE')
    and not has_table_privilege('anon', 'mirror.audit_logs', 'SELECT')
    and not has_table_privilege('authenticated', 'mirror.audit_logs', 'SELECT');
  r := r || format('1 service_role cannot truncate; anon/authenticated no access: %s', ok);

  -- 2 service_role is refused by the grant
  execute 'set local role service_role';
  begin execute 'truncate mirror.audit_logs'; ok := false; exception when insufficient_privilege then ok := true; end;
  execute 'reset role';
  r := r || format('2 TRUNCATE as service_role refused: %s', ok);

  -- 3 the owner is refused by the trigger (log has a row first, and still has it after)
  perform mirror.audit(null, null, 'check', 'fix14_check', 'general');
  select count(*) into n from mirror.audit_logs;
  begin execute 'truncate mirror.audit_logs'; ok := false; exception when insufficient_privilege then ok := true; end;
  ok := ok and (select count(*) from mirror.audit_logs) = n and n > 0;
  r := r || format('3 TRUNCATE as owner refused, rows kept: %s', ok);

  -- 4 normal logging still works and UPDATE/DELETE are still refused
  ok := true;
  begin update mirror.audit_logs set reason = 'x' where action = 'fix14_check'; ok := false; exception when insufficient_privilege then null; end;
  begin delete from mirror.audit_logs where action = 'fix14_check'; ok := false; exception when insufficient_privilege then null; end;
  r := r || format('4 inserts work; UPDATE and DELETE still refused: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
