-- Mirror Daily Number step 3 check: cost-of-being-poor kinds and the six Daily Number reflections. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; n int; ok boolean;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.u@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.uc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select count(*) into n from mirror.question_sets where kind = 'module' and key like 'dn\_%';
  r := r || format('1 Daily Number reflections: %s sets (6), %s questions (24)', n,
    (select count(*) from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.key like 'dn\_%'));

  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.u@example.invalid', 'CHECK U') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.uc@example.invalid', 'CHECK UC', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);

  -- 2. a cost of being poor: choosing a kind marks it; it shows in the inputs; an unknown kind is refused; clearing it keeps the line
  j := public.mirror_dn_save('expense', '{"level":"current","category":"household","label":"Laundromat","amount":"40","frequency":"monthly","premium_kind":"laundromat"}');
  ok := round((j #>> '{levels,current,poverty_premium,monthly}')::numeric, 2) = 40;
  j := public.mirror_dn_get();
  ok := ok and (select e ->> 'premium_kind' = 'laundromat' and (e ->> 'poverty_premium')::boolean from jsonb_array_elements(j #> '{inputs,expenses}') e where e ->> 'label' = 'Laundromat');
  begin perform public.mirror_dn_save('expense', '{"level":"current","category":"household","label":"x","amount":"5","frequency":"monthly","premium_kind":"nonsense"}'); ok := ok and false; exception when invalid_parameter_value then null; end;
  perform public.mirror_dn_save('expense', jsonb_build_object('id', (select e ->> 'id' from jsonb_array_elements(j #> '{inputs,expenses}') e where e ->> 'label' = 'Laundromat'),
    'level', 'current', 'category', 'household', 'label', 'Laundromat', 'amount', '40', 'frequency', 'monthly', 'premium_kind', '', 'poverty_premium', false));
  j := public.mirror_dn_get();
  ok := ok and round((j #>> '{results,levels,current,poverty_premium,monthly}')::numeric, 2) = 0 and jsonb_array_length(j #> '{inputs,expenses}') = 1;
  r := r || format('2 cost-of-being-poor kind: marks the line ($40/month), shows in the inputs, unknown kind refused, can be cleared: %s', ok);

  -- 3. the person answers a Daily Number reflection; money reflections are private, the work reflection is not
  perform public.mirror_answer_save('dn_gap', 'runs_out', '"most"');
  perform public.mirror_answer_save('dn_generate', 'work_want', '"Home health aide"');
  j := public.mirror_sets('module');
  ok := (select (s ->> 'answered')::int from jsonb_array_elements(j) s where s ->> 'key' = 'dn_gap') = 1;
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_set_get('dn_gap', a); ok := ok and false; exception when insufficient_privilege then null; end;
  j := public.mirror_set_get('dn_generate', a);
  ok := ok and (select q -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'work_want') = 'Home health aide'
    and (select (q ->> 'hidden')::boolean from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'benefits');
  execute 'reset role';
  r := r || format('3 person answers; coordinator without money sharing: gap reflection refused, work reflection seen, benefits question hidden: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
