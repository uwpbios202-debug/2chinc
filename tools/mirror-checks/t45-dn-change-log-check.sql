-- Mirror Daily Number step 5 check: field-by-field change log of edits made by someone helping the person.
-- Fictional people; always rolled back. Run: sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> tools/mirror-checks/t45-dn-change-log-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; ok boolean; e uuid; fd uuid; n int;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p45@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p45c@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  sx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p45s@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p45@example.invalid', 'CHECK P45') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.p45c@example.invalid', 'Pat Coordinator', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (a, x, 'financial', 'edit', 'check.p45@example.invalid');

  -- 1. the person's own edits are not logged
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('settings', '{"tax_rate_pct":"10"}');
  perform public.mirror_dn_save('expense', '{"level":"stability","category":"housing","label":"Rent","amount":"1200","frequency":"monthly"}');
  perform public.mirror_dn_save('expense', '{"level":"stability","category":"food","label":"Food","amount":"400","frequency":"monthly"}');
  execute 'reset role';
  n := (select count(*) from mirror.dn_changes where individual_id = a);
  select id into e from mirror.living_expenses where individual_id = a and label = 'Rent';
  select id into fd from mirror.living_expenses where individual_id = a and label = 'Food';
  r := r || format('1 the person''s own 3 edits: %s lines logged (0)', n);

  -- 2. a coordinator with money sharing changes the rent amount only: one line, field amount, 1200.00 -> 1150.00
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_dn_save('expense', jsonb_build_object('id', e, 'level', 'stability', 'category', 'housing', 'label', 'Rent', 'amount', '1150', 'frequency', 'monthly'), a);
  execute 'reset role';
  ok := (select count(*) from mirror.dn_changes where individual_id = a) = 1
    and (select field = 'amount' and old_value::numeric = 1200 and new_value::numeric = 1150 and action = 'changed' and actor_role = 'coordinator'
           and organization_id = x and row_label = 'Rent' and table_name = 'living_expenses' and row_id = e::text from mirror.dn_changes where individual_id = a);
  r := r || format('2 coordinator changes rent $1,200 -> $1,150: exactly one line (amount, 1200 -> 1150, coordinator, their organization): %s', ok);

  -- 3. the coordinator adds a line, changes the tax rate, removes Food: added / changed / removed lines
  perform set_config('role', 'authenticated', true);
  perform public.mirror_dn_save('income', '{"kind":"cash_benefit","label":"SSI","amount":"943","frequency":"monthly"}', a);
  perform public.mirror_dn_save('settings', '{"tax_rate_pct":"12"}', a);
  perform public.mirror_dn_delete('expense', fd, a);
  execute 'reset role';
  ok := (select count(*) from mirror.dn_changes where individual_id = a and action = 'added' and table_name = 'income_sources' and row_label = 'SSI' and new_value::jsonb ->> 'amount' = '943.00') = 1
    and (select count(*) from mirror.dn_changes where individual_id = a and action = 'changed' and table_name = 'daily_number_settings' and field = 'tax_rate_pct'
         and old_value::numeric = 10 and new_value::numeric = 12 and row_label = 'Settings') = 1
    and (select count(*) from mirror.dn_changes where individual_id = a and action = 'removed' and row_label = 'Food' and old_value::jsonb ->> 'amount' = '400.00') = 1;
  r := r || format('3 coordinator adds SSI $943, tax 10%% -> 12%%, removes Food $400: one added, one changed, one removed line: %s', ok);

  -- 4. the person reads the log: newest first, the coordinator by name, never an email; also in the download
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_dn_changes();
  ok := jsonb_array_length(j) = 4 and j #>> '{0,label}' = 'Food' and j #>> '{0,who}' = 'Pat Coordinator' and position('@' in j::text) = 0;
  j := public.mirror_my_export();
  ok := ok and jsonb_array_length(j #> '{daily_number,changes}') = 4;
  -- the person's own edit after the coordinator's still is not logged
  perform public.mirror_dn_save('expense', jsonb_build_object('id', e, 'level', 'stability', 'category', 'housing', 'label', 'Rent', 'amount', '1175', 'frequency', 'monthly'));
  execute 'reset role';
  ok := ok and (select count(*) from mirror.dn_changes where individual_id = a) = 4;
  r := r || format('4 person sees 4 lines, newest first, "Pat Coordinator", no email; download has them; their own later edit adds none: %s', ok);

  -- 5. closed: someone with no link to the person cannot read the log; the table cannot be read directly
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', sx, true);
  ok := true;
  begin perform public.mirror_dn_changes(a); ok := false; exception when insufficient_privilege then null; end;
  begin perform count(*) from mirror.dn_changes; ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  r := r || format('5 a signed-in stranger is refused; the table is closed to direct reads: %s', ok);

  -- 6. deleting the person removes the log and logs nothing more
  delete from mirror.individuals where id = a;
  r := r || format('6 person deleted: change lines left %s (0)', (select count(*) from mirror.dn_changes where individual_id = a));

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
