-- Mirror T8.6 check: benefits applications for the organization (D-37). Money (financial) must be shared; the dashboard lists renewals due
-- in 30 days or passed and appeal deadlines in 30 days only for people who share Money; changes through mirror_dn_save need "see and
-- change" and show who changed last; another organization sees nothing; looks are logged. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t86-benefits-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; j jsonb; e jsonb; n int; ok boolean; fs uuid;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; cx text; cy text; t date := (now() at time zone 'America/Chicago')::date;
begin
  insert into auth.users (id, email) values (ua, 'check.ba@example.invalid'), (uc, 'check.bcx@example.invalid'), (uy, 'check.bcy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
  values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now()), (sy, uy, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ba@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.bcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  cy := json_build_object('sub', uy, 'email', 'check.bcy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK BY', 'nonprofit') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.ba@example.invalid', 'CHECK BA', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.bcx@example.invalid', 'CHECK BCX', 'coordinator'), (y, 'check.bcy@example.invalid', 'CHECK BCY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- the person's four records: FoodShare renewal in 10 days, SSI denied (appeal by in 20), BadgerCare renewal in 90, energy renewal passed
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform public.mirror_dn_save('benefit', jsonb_build_object('program', 'CHECK FoodShare', 'kind', 'food', 'status', 'active', 'renewal_on', t + 10));
  perform public.mirror_dn_save('benefit', jsonb_build_object('program', 'CHECK SSI', 'kind', 'cash', 'status', 'denied', 'appeal_by', t + 20));
  perform public.mirror_dn_save('benefit', jsonb_build_object('program', 'CHECK BadgerCare', 'kind', 'health', 'status', 'active', 'renewal_on', t + 90));
  perform public.mirror_dn_save('benefit', jsonb_build_object('program', 'CHECK Energy help', 'kind', 'energy', 'status', 'active', 'renewal_on', t - 5));

  -- 1. Money not shared: refused, and the dashboard does not count them
  perform set_config('request.jwt.claims', cx, true);
  ok := true;
  begin perform public.mirror_benefits(a, x); ok := false; exception when others then null; end;
  ok := ok and jsonb_array_length(public.mirror_benefit_dates(x) -> 'dates') = 0;
  r := r || format('1 Money not shared: the benefits are refused and nothing is on the dashboard: %s', ok);

  -- 2. Money shared "see": 4 records, no editing; the dashboard lists FoodShare renewal, SSI appeal, energy renewal (passed), not BadgerCare
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'financial', 'view');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_benefits(a, x);
  ok := jsonb_array_length(j -> 'benefits') = 4 and not (j ->> 'can_edit')::boolean;
  j := public.mirror_benefit_dates(x) -> 'dates';
  ok := ok and jsonb_array_length(j) = 3
    and exists (select 1 from jsonb_array_elements(j) v where v ->> 'program' = 'CHECK Energy help' and (v ->> 'passed')::boolean)
    and exists (select 1 from jsonb_array_elements(j) v where v ->> 'program' = 'CHECK SSI' and v ->> 'what' = 'appeal')
    and not exists (select 1 from jsonb_array_elements(j) v where v ->> 'program' = 'CHECK BadgerCare');
  r := r || format('2 Money "see": 4 records, read only; dashboard: 2 renewals (1 passed) and 1 appeal deadline, nothing beyond 30 days: %s', ok);

  -- 3. "see" cannot save; "see and change" can (new renewal date), and the record says a coordinator changed it last
  select (v ->> 'id')::uuid into fs from jsonb_array_elements(public.mirror_benefits(a, x) -> 'benefits') v where v ->> 'program' = 'CHECK FoodShare';
  ok := true;
  begin perform public.mirror_dn_save('benefit', jsonb_build_object('id', fs, 'program', 'CHECK FoodShare', 'kind', 'food', 'status', 'active', 'renewal_on', t + 200), a);
    ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'financial', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_dn_save('benefit', jsonb_build_object('id', fs, 'program', 'CHECK FoodShare', 'kind', 'food', 'status', 'active', 'renewal_on', t + 200), a);
  select v into e from jsonb_array_elements(public.mirror_benefits(a, x) -> 'benefits') v where v ->> 'id' = fs::text;
  ok := ok and e ->> 'renewal_on' = (t + 200)::text and e ->> 'last_by' = 'coordinator'
    and jsonb_array_length(public.mirror_benefit_dates(x) -> 'dates') = 2;
  perform set_config('request.jwt.claims', pa, true);
  select v into e from jsonb_array_elements(public.mirror_benefits() -> 'benefits') v where v ->> 'id' = fs::text;
  ok := ok and e ->> 'last_by' = 'coordinator';
  r := r || format('3 "see" cannot change; "see and change" moves the renewal (dashboard now 2); the person sees a coordinator changed it: %s', ok);

  -- 4. the looks at Money were logged for the person
  execute 'reset role';
  select count(*) into n from mirror.audit_logs l where l.individual_id = a and l.category = 'financial' and l.table_name in ('benefit_records', 'workspace_dashboard');
  perform set_config('role', 'authenticated', true);
  ok := n >= 2;
  r := r || format('4 looks at their Money logged for them (%s): %s', n, ok);

  -- 5. another organization: refused, and nothing on its dashboard
  perform set_config('request.jwt.claims', cy, true);
  ok := true;
  begin perform public.mirror_benefits(a, y); ok := false; exception when others then null; end;
  begin perform public.mirror_benefit_dates(x); ok := false; exception when others then null; end;
  ok := ok and jsonb_array_length(public.mirror_benefit_dates(y) -> 'dates') = 0;
  r := r || format('5 another organization sees nothing: %s', ok);

  -- 6. a coordinator's save passes the person's Daily Number link back (as the workspace form does), so the link is kept
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_dn_save('income', jsonb_build_object('label', 'CHECK food money', 'amount', '200', 'frequency', 'monthly'));
  execute 'reset role';
  select id into e from (select to_jsonb(s.id) as id from mirror.income_sources s where s.individual_id = a limit 1) z;
  perform set_config('role', 'authenticated', true);
  perform public.mirror_dn_save('benefit', jsonb_build_object('id', fs, 'program', 'CHECK FoodShare', 'kind', 'food', 'status', 'active',
    'renewal_on', t + 200, 'income_source_id', e #>> '{}'));
  perform set_config('request.jwt.claims', cx, true);
  select v into j from jsonb_array_elements(public.mirror_benefits(a, x) -> 'benefits') v where v ->> 'id' = fs::text;
  perform public.mirror_dn_save('benefit', (j - 'updated_at' - 'last_by') || jsonb_build_object('note', 'CHECK renewal sent'), a);
  select v into j from jsonb_array_elements(public.mirror_benefits(a, x) -> 'benefits') v where v ->> 'id' = fs::text;
  ok := j ->> 'income_source_id' = e #>> '{}' and j ->> 'note' = 'CHECK renewal sent';
  r := r || format('6 a coordinator''s change keeps the person''s link to their income line: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
