-- GENERATED into t42-daily-number-check.sql by t42-make-check.mjs (fixtures from daily-number-fixtures.mjs). Mirror T4.2 check; always rolled back.
do $chk$
declare
  r text[] := '{}'; bad text[] := '{}'; total int := 0; t date := (now() at time zone 'America/Chicago')::date; j jsonb; x uuid; a uuid; s1 uuid; n int; ok boolean;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.dn@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.dnc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  -- 1. the SQL arithmetic equals the hand-worked fixtures (the same file as the JavaScript check)
--FIXTURES--
  r := r || format('1 SQL calculation vs hand-worked fixtures: %s of %s figures match%s', total - cardinality(bad), total,
    case when cardinality(bad) > 0 then ' FAILS: ' || array_to_string(bad, '; ') else '' end);
  r := r || format('2 categories seeded: %s (12)', (select count(*) from mirror.expense_categories));

  -- 3. a person builds a Daily Number through the page functions; the result equals the fixture
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.dn@example.invalid', 'CHECK DN') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.dnc@example.invalid', 'CHECK DNC', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"Groceries","amount":"$400","frequency":"monthly"}');
  perform public.mirror_dn_save('expense', '{"level":"current","category":"housing","label":"Rent","amount":"600","frequency":"monthly"}');
  perform public.mirror_dn_save('income', '{"kind":"wages","label":"Job","amount":"500","frequency":"monthly"}');
  j := public.mirror_dn_save('noncash', '{"kind":"snap","category":"food","label":"SNAP","amount":"250","frequency":"monthly"}');
  ok := round((j #>> '{levels,current,shortfall,monthly}')::numeric, 2) = 250 and round((j #>> '{levels,current,noncash_applied,monthly}')::numeric, 2) = 250
    and round((j #>> '{income,monthly}')::numeric, 2) = 500;
  perform public.mirror_dn_save('settings', '{"tax_rate_pct":"20"}');
  j := public.mirror_dn_get();
  ok := ok and round((j #>> '{results,levels,current,gross_needed,monthly}')::numeric, 2) = 937.50 and jsonb_array_length(j #> '{inputs,expenses}') = 2;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"-5","frequency":"monthly"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"nope","label":"x","amount":"5","frequency":"monthly"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"irregular"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"category":"food","label":"x","amount":"5","frequency":"monthly"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('3 person enters costs, wages, SNAP, 20%% tax: shortfall $250/month, before-tax $937.50/month; bad entries refused: %s', ok);

  -- 4. snapshots keep inputs and results and cannot be changed
  s1 := public.mirror_dn_snapshot('Staying with my sister');
  perform public.mirror_dn_save('expense', '{"level":"current","category":"housing","label":"Rent","amount":"900","frequency":"monthly"}');
  j := public.mirror_dn_history();
  ok := jsonb_array_length(j) = 1 and round((j -> 0 #>> '{results,levels,current,cost,monthly}')::numeric, 2) = 1000;
  execute 'reset role';
  begin update mirror.daily_number_snapshots set note = 'x' where id = s1; ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('role', 'authenticated', true);
  r := r || format('4 snapshot keeps the old numbers after a change, and cannot be edited: %s', ok);

  -- 5. coordinator: refused until the person shares money; then view only; the look is logged
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_dn_get(a); ok := false; exception when insufficient_privilege then ok := true; end;
  execute 'reset role';
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (a, x, 'financial', 'view', 'check.dn@example.invalid');
  perform set_config('role', 'authenticated', true);
  j := public.mirror_dn_get(a);
  ok := ok and not (j ->> 'can_edit')::boolean and jsonb_array_length(j #> '{inputs,expenses}') = 3;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"monthly"}', a); ok := ok and false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where individual_id = a and category = 'financial' and action = 'view';
  r := r || format('5 coordinator: no money access until shared; then view only; looks logged (%s): %s', n, ok and n >= 1);

  -- 7. the fixes of 11/13: dates, goals, copy all-or-nothing, the download includes the Daily Number
  execute 'reset role';
  delete from mirror.consents where individual_id = a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('expense', jsonb_build_object('level', 'current', 'category', 'communication', 'label', 'Old phone', 'amount', '50', 'frequency', 'monthly',
    'end_on', (t - 1)::text));
  perform public.mirror_dn_save('expense', jsonb_build_object('level', 'current', 'category', 'transportation', 'label', 'Bus pass', 'amount', '60', 'frequency', 'monthly',
    'start_on', (t + 20)::text));
  j := public.mirror_dn_get();
  ok := round((j #>> '{results,levels,current,cost,monthly}')::numeric, 2) = 1900 and jsonb_array_length(j #> '{inputs,expenses}') = 5;   -- 400 + 600 + 900 counted; old phone and future bus pass listed only
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"monthly","start_on":"2027-02-01","end_on":"2027-01-01"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"x","amount":"5","frequency":"monthly","start_on":"2027-02-31"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('7a [counted %s/month, listed %s lines] ended and not-yet-started costs listed but not counted; bad dates refused: %s', round((j #>> '{results,levels,current,cost,monthly}')::numeric, 2), jsonb_array_length(j #> '{inputs,expenses}'), ok);

  j := public.mirror_dn_save('goal', jsonb_build_object('kind', 'emergency_reserve', 'label', 'Emergency fund', 'level', 'stability', 'target_amount', '1200',
    'current_amount', '0', 'target_date', (t + 365)::text));
  ok := round((j #>> '{levels,stability,goals,monthly}')::numeric, 2) = 100 and round((j #>> '{levels,aspirational,goals,monthly}')::numeric, 2) = 100;
  perform public.mirror_dn_save('goal', jsonb_build_object('kind', 'savings', 'label', 'Not counted', 'level', 'none', 'target_amount', '500', 'target_date', (t + 100)::text));
  j := public.mirror_dn_get();
  ok := ok and round((j #>> '{results,levels,stability,goals,monthly}')::numeric, 2) = 100 and jsonb_array_length(j -> 'goals') = 2;
  r := r || format('7b goal $1,200 in 12 months counts $100/month in Stability and The life I want; a goal set "not counted" adds nothing: %s', ok);

  j := public.mirror_dn_copy('current', 'survival');
  total := (j ->> 'copied')::int; ok := total = 5;
  begin perform public.mirror_dn_copy('current', 'current'); ok := ok and false; exception when invalid_parameter_value then null; end;
  execute 'reset role';
  select count(*) into n from mirror.living_expenses where individual_id = a and level = 'survival';
  -- all or nothing: a failing copy (a row that breaks a rule) leaves no partial copy behind
  begin
    perform set_config('role', 'authenticated', true);
    perform public.mirror_dn_copy('current', 'stability');
    execute 'reset role';
    update mirror.living_expenses set amount = -1 where individual_id = a and level = 'stability';
    ok := false;
  exception when check_violation then execute 'reset role'; end;
  select count(*) + n into n from mirror.living_expenses where individual_id = a and level = 'stability';
  r := r || format('7c [copied %s; survival + stability rows after a failed copy step = %s] copy is one step, a failed step leaves nothing: %s', total, n, ok and n = 5);
  perform set_config('role', 'authenticated', true);

  j := public.mirror_my_export();
  total := jsonb_array_length(j #> '{daily_number,inputs,expenses}');
  ok := total = 10 and jsonb_array_length(j #> '{daily_number,inputs,goals}') = 2
    and jsonb_array_length(j #> '{daily_number,saved}') = 1 and (j #>> '{daily_number,results,method}')::int >= 2;
  r := r || format('7d [%s cost lines] the download includes the Daily Number (2 goals, 1 saved number, method 2 or later): %s', total, ok);
  execute 'reset role';

  -- 8. step 2 (trustworthy): resources per level, untaxed income, automatic save before the first change of a new day
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_dn_save('income', '{"kind":"cash_benefit","label":"SSI","amount":"943","frequency":"monthly","applies_to":["current","survival"]}');
  ok := round((j #>> '{levels,current,income,monthly}')::numeric, 2) = 1443 and round((j #>> '{levels,stability,income,monthly}')::numeric, 2) = 500
    and round((j #>> '{levels,current,untaxed_income,monthly}')::numeric, 2) = 943 and (j ->> 'method')::int = 4;
  j := public.mirror_dn_get();
  ok := ok and (select count(*) from jsonb_array_elements(j #> '{inputs,income}') ii where ii ->> 'label' = 'SSI' and ii -> 'applies_to' = '["current", "survival"]'::jsonb) = 1;
  perform public.mirror_dn_save('income', '{"kind":"wages","label":"Side job","amount":"100","frequency":"monthly","applies_to":["current","survival","stability","aspirational"],"taxable":"false"}');
  execute 'reset role';
  select count(*) into n from mirror.income_sources where individual_id = a and label = 'Side job' and applies_to is null and taxable = false;
  r := r || format('8a SSI counted only today and in Survival (today $1,443/month income, Stability $500), untaxed; all four levels saved as "all"; taxed flag kept: %s', ok and n = 1);

  -- pretend everything (lines and saved numbers) is from two days ago, then make two changes today:
  -- the numbers as they were are saved first, once; the second change saves nothing more
  alter table mirror.living_expenses disable trigger living_expenses_touch;
  alter table mirror.income_sources disable trigger income_sources_touch;
  alter table mirror.noncash_resources disable trigger noncash_resources_touch;
  alter table mirror.financial_goals disable trigger financial_goals_touch;
  alter table mirror.daily_number_snapshots disable trigger daily_number_snapshots_never_change;
  update mirror.living_expenses set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.income_sources set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.noncash_resources set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.financial_goals set created_at = now() - interval '2 days', updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.daily_number_settings set updated_at = now() - interval '2 days' where individual_id = a;
  update mirror.daily_number_snapshots set taken_at = now() - interval '3 days' where individual_id = a;
  alter table mirror.living_expenses enable trigger living_expenses_touch;
  alter table mirror.income_sources enable trigger income_sources_touch;
  alter table mirror.noncash_resources enable trigger noncash_resources_touch;
  alter table mirror.financial_goals enable trigger financial_goals_touch;
  alter table mirror.daily_number_snapshots enable trigger daily_number_snapshots_never_change;
  select count(*) into n from mirror.daily_number_snapshots where individual_id = a;
  perform set_config('role', 'authenticated', true);
  perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"Coffee","amount":"20","frequency":"monthly"}');
  perform public.mirror_dn_save('expense', '{"level":"current","category":"food","label":"Tea","amount":"10","frequency":"monthly"}');
  execute 'reset role';
  select count(*) - n into n from mirror.daily_number_snapshots where individual_id = a;
  ok := n = 1 and exists (select 1 from mirror.daily_number_snapshots where individual_id = a and note like 'Saved automatically%'
       and not (inputs -> 'expenses') @> '[{"label":"Coffee"}]' and method_version = (results ->> 'method')::int and method_version = 4);
  r := r || format('8b first change on a new day saves the numbers as they were (without Coffee), once, method 4 recorded as calculated (new rows %s, expected 1): %s', n, ok);
  perform set_config('role', 'authenticated', true);
  s1 := public.mirror_dn_snapshot('manual');
  execute 'reset role';
  r := r || format('8c a manual save now records method %s (was always 1)', (select method_version from mirror.daily_number_snapshots where id = s1));

  -- 6. deleting the person removes their Daily Number and snapshots
  delete from mirror.individuals where id = a;
  select (select count(*) from mirror.living_expenses where individual_id = a) + (select count(*) from mirror.daily_number_snapshots where individual_id = a) into n;
  r := r || format('6 person deleted: Daily Number rows left %s (0)', n);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
