-- Mirror Daily Number step 4 check: household, benefit and subsidy records, income opportunities ("It started" makes income).
-- Fictional people; always rolled back. Run: sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration> tools/mirror-checks/t44-daily-number-plan-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; n int; ok boolean; m uuid; m2 uuid; nc uuid; op uuid; inc uuid; ex uuid;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p4@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pb text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p4b@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.p4c@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p4@example.invalid', 'CHECK P4') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.p4b@example.invalid', 'CHECK P4B') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.p4c@example.invalid', 'CHECK P4C', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');

  -- person B has a household member (used below to prove A cannot link to it)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pb, true);
  perform public.mirror_dn_save('member', '{"label":"B sister","relationship":"sibling"}');
  execute 'reset role';
  select id into m2 from mirror.household_members where individual_id = b;

  -- 1. household: a member; a cost they pay counts as "paid for you"; money they give is income; another person's member is refused
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('settings', '{"tax_rate_pct":"10"}');
  j := public.mirror_dn_save('member', '{"label":"My sister","relationship":"sibling","lives_with":"true"}');
  j := public.mirror_dn_get();
  m := (j #>> '{plan,members,0,id}')::uuid;
  j := public.mirror_dn_save('expense', jsonb_build_object('level', 'stability', 'category', 'housing', 'label', 'Rent share', 'amount', '600', 'frequency', 'monthly',
    'paid_by', 'household', 'household_member_id', m));
  ok := round((j #>> '{levels,stability,paid_by_others,monthly}')::numeric, 2) = 600 and round((j #>> '{levels,stability,cash_expenses,monthly}')::numeric, 2) = 0;
  j := public.mirror_dn_save('income', jsonb_build_object('kind', 'family_support', 'label', 'From my sister', 'amount', '100', 'frequency', 'monthly', 'household_member_id', m));
  ok := ok and round((j #>> '{levels,stability,income,monthly}')::numeric, 2) = 100;
  j := public.mirror_dn_get();
  ok := ok and (select count(*) from jsonb_array_elements(j #> '{inputs,expenses}') e where (e ->> 'household_member_id')::uuid = m) = 1
    and (select count(*) from jsonb_array_elements(j #> '{inputs,income}') i where (i ->> 'household_member_id')::uuid = m) = 1;
  begin perform public.mirror_dn_save('income', jsonb_build_object('kind', 'family_support', 'label', 'x', 'amount', '5', 'frequency', 'monthly', 'household_member_id', m2));
    ok := ok and false; exception when invalid_parameter_value then null; end;
  -- a cost paid by the person themselves drops a stray member link
  perform public.mirror_dn_save('expense', jsonb_build_object('level', 'stability', 'category', 'food', 'label', 'Groceries', 'amount', '300', 'frequency', 'monthly',
    'paid_by', 'self', 'household_member_id', m));
  execute 'reset role';
  ok := ok and (select household_member_id is null from mirror.living_expenses where individual_id = a and label = 'Groceries');
  r := r || format('1 household: member saved; rent share paid by them = $600 paid for you, $0 cash; $100 from them = income; links shown; another person''s member refused; self-paid cost keeps no member link: %s', ok);

  -- 2. benefit records: linked to the person's own help line; renewal and appeal dates kept; a link to someone else's line is refused
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('noncash', '{"kind":"snap","label":"FoodShare","category":"food","amount":"250","frequency":"monthly"}');
  execute 'reset role';
  select id into nc from mirror.noncash_resources where individual_id = a;
  perform set_config('role', 'authenticated', true);
  j := public.mirror_dn_save('benefit', jsonb_build_object('program', 'FoodShare', 'kind', 'food', 'status', 'active', 'renewal_on', '2027-03-01', 'appeal_by', '', 'noncash_id', nc));
  ok := round((j #>> '{levels,stability,noncash_applied,monthly}')::numeric, 2) = 250;     -- counted once, on its line
  j := public.mirror_dn_get();
  ok := ok and j #>> '{plan,benefits,0,renewal_on}' = '2027-03-01' and (j #>> '{plan,benefits,0,noncash_id}')::uuid = nc;
  begin perform public.mirror_dn_save('benefit', jsonb_build_object('program', 'x', 'expense_id', gen_random_uuid())); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('benefit', '{"program":"x","renewal_on":"2027-02-30"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('benefit', '{"program":"x","status":"maybe"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  r := r || format('2 benefit record: linked to FoodShare ($250 counted once), renewal date kept; unknown line, impossible date, unknown status refused: %s', ok);

  -- 3. opportunity: not counted until it starts; "It started" adds take-home income ($300/week before taxes at 10%% = $270/week) in one step
  j := public.mirror_dn_save('opportunity', '{"kind":"job","label":"Warehouse job","amount":"300","frequency":"weekly","amount_is_gross":"true","status":"working_on","expected_on":"2026-12-01","next_step":"Call back Monday"}');
  ok := round((j #>> '{levels,stability,income,monthly}')::numeric, 2) = 100;               -- unchanged: only the sister's $100
  j := public.mirror_dn_get();
  op := (j #>> '{plan,opportunities,0,id}')::uuid;
  ok := ok and j #>> '{plan,opportunities,0,next_step}' = 'Call back Monday';
  begin perform public.mirror_dn_save('opportunity', '{"kind":"job","label":"x","amount":"5","frequency":"weekly","status":"started"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  j := public.mirror_dn_save('opportunity_start', jsonb_build_object('id', op, 'start_on', '2026-11-01'));
  -- $270 x 365 / 7 / 12 = $1,173.21 a month, + $100 = $1,273.21
  ok := ok and round((j #>> '{levels,stability,income,monthly}')::numeric, 2) = 1273.21;
  begin perform public.mirror_dn_save('opportunity_start', jsonb_build_object('id', op)); ok := ok and false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_dn_save('opportunity', jsonb_build_object('id', op, 'kind', 'job', 'label', 'x', 'amount', '1', 'frequency', 'weekly', 'status', 'idea'));
    ok := ok and false; exception when no_data_found then null; end;
  execute 'reset role';
  select income_source_id into inc from mirror.income_opportunities where id = op and status = 'started';
  ok := ok and inc is not null and (select amount = 270 and kind = 'wages' and taxable and start_on = '2026-11-01' and note like 'From my plan ($300.00 before taxes, 10% tax)'
    from mirror.income_sources where id = inc);
  r := r || format('3 opportunity not counted until it starts; started = income $270/week (wages, taxed, from 11/1, note says $300 before taxes at 10%%), $1,273.21/month in all; cannot start twice, cannot be set "started" by hand or changed after: %s', ok);

  -- 4. copy keeps "could go down" kind and the payer link (the old copy lost the kind)
  perform set_config('role', 'authenticated', true);
  perform public.mirror_dn_save('expense', '{"level":"current","category":"household","label":"Laundromat","amount":"40","frequency":"monthly","premium_kind":"laundromat"}');
  perform public.mirror_dn_copy('stability', 'survival');
  perform public.mirror_dn_copy('current', 'aspirational');
  execute 'reset role';
  ok := (select premium_kind = 'laundromat' from mirror.living_expenses where individual_id = a and level = 'aspirational' and label = 'Laundromat')
    and (select household_member_id = m and paid_by = 'household' from mirror.living_expenses where individual_id = a and level = 'survival' and label = 'Rent share');
  r := r || format('4 copy keeps the "could go down" kind and who in the household pays: %s', ok);

  -- 5. coordinator without money sharing: no plan; tables closed to direct reads; the download includes the plan
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  ok := true;
  begin perform public.mirror_dn_get(a); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_dn_save('member', '{"label":"x"}'::jsonb, a); ok := false; exception when insufficient_privilege then null; end;
  begin perform count(*) from mirror.household_members; ok := false; exception when insufficient_privilege then null; end;
  begin perform count(*) from mirror.benefit_records; ok := false; exception when insufficient_privilege then null; end;
  begin perform count(*) from mirror.income_opportunities; ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export();
  ok := ok and jsonb_array_length(j #> '{daily_number,plan,members}') = 1 and jsonb_array_length(j #> '{daily_number,plan,benefits}') = 1
    and jsonb_array_length(j #> '{daily_number,plan,opportunities}') = 1;
  -- removing the member keeps the money lines (link cleared)
  perform public.mirror_dn_delete('member', m);
  execute 'reset role';
  ok := ok and (select count(*) from mirror.living_expenses where individual_id = a and label = 'Rent share' and household_member_id is null) = 2;
  r := r || format('5 coordinator without money sharing: plan refused (view and edit); new tables closed to direct reads; download has members, benefits, opportunities; removing a member keeps their lines: %s', ok);

  -- 6. deleting the person removes every plan record
  delete from mirror.individuals where id in (a, b);
  r := r || format('6 people deleted: plan rows left %s (0)', (select count(*) from mirror.household_members where individual_id in (a, b))
    + (select count(*) from mirror.benefit_records where individual_id in (a, b)) + (select count(*) from mirror.income_opportunities where individual_id in (a, b)));

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
