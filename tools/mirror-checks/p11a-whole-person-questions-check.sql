-- Mirror Phase 11 check: the whole-person questions (migration 20261119700000). Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; pv uuid; ok boolean; j jsonb; n int;
  uv uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sv uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); jv text; jc text;
  keys text[] := array['cl_laundry_access','cl_laundry_often','cl_laundry_cost','cl_condition','cl_needs','cl_barriers','hf_have','hf_need_first','hf_moving','hf_help',
    'su_use','su_support','su_helps','su_hard','su_housing','su_help','gl_loss','gl_now','gl_support','gl_help','ji_history','ji_supervision','ji_requirements','ji_fees',
    'ji_effects','ji_clear','ji_help','vet_served','vet_papers','vet_va','vet_help','dc_kinds','dc_total','dc_collections','dc_credit','dc_goal','dc_help',
    'cg_children','cg_childcare','cg_who','cg_kids_needs','cg_custody','cg_other','cg_load','cg_help'];
begin
  -- 1. all 45 are there, in the right areas, with the right privacy
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where q.key = any (keys) and q.active and s.kind = 'dimension';
  ok := n = 45
    and not exists (select 1 from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where q.key = any (keys) and (
          (q.key like 'su\_%' or q.key like 'gl\_%') and (s.dimension_key <> 'mental_health' or q.category <> 'mental_health')
       or (q.key like 'ji\_%' or q.key like 'vet\_%') and (s.dimension_key <> 'identity_legal' or q.category <> case when q.key = 'ji_fees' then 'financial' else 'legal' end)
       or q.key like 'dc\_%' and (s.dimension_key <> 'finances' or q.category <> 'financial')
       or q.key like 'cg\_%' and (s.dimension_key <> 'relationships' or q.category <> case when q.key = 'cg_custody' then 'legal' else 'general' end)
       or q.key like 'hf\_%' and (s.dimension_key <> 'housing' or q.category <> 'general')
       or q.key like 'cl\_%' and (s.dimension_key <> 'self_care' or q.category <> case when q.key = 'cl_laundry_cost' then 'financial' else 'general' end)));
  r := r || format('1 45 questions in the right areas with the right privacy (%s found): %s', n, ok);

  -- 2. each has its first wording recorded (version 1); choices are value/label lists; sorts unique within each area
  ok := (select count(*) from mirror.question_versions v join mirror.reflection_questions q on q.id = v.question_id where q.key = any (keys) and v.version = 1) = 45
    and not exists (select 1 from mirror.reflection_questions q where q.key = any (keys) and q.answer_type in ('choice', 'multi')
                    and (jsonb_array_length(q.options) < 2 or exists (select 1 from jsonb_array_elements(q.options) e where e ->> 'value' is null or e ->> 'label' is null)))
    and not exists (select 1 from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'dimension' group by q.set_id, q.sort having count(*) > 1);
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id where s.kind = 'dimension' and q.active;
  r := r || format('2 wording recorded, choices well formed, sorts unique; %s life-area questions in all (195 expected): %s', n, ok and n = 195);

  -- 3. the person answers; a coordinator (general sharing only) sees the children question but not custody, and not the private areas
  insert into auth.users (id, email) values (uv, 'check.wv@example.invalid'), (uc, 'check.wc@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sv, uv, now(), now(), now(), 'aal1'), (sc, uc, now(), now(), now(), 'aal2');
  jv := json_build_object('sub', uv, 'email', 'check.wv@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sv)::text;
  jc := json_build_object('sub', uc, 'email', 'check.wc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  insert into mirror.organizations (name, kind) values ('CHECK whole person org', 'nonprofit') returning id into o;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.wc@example.invalid', 'CHECK WC', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.wv@example.invalid', 'CHECK WV', o) returning id into pv;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (o, pv, 'active', current_date);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jv, true);
  perform public.mirror_answer_save('dimension_relationships', 'cg_children', '"with_me"'::jsonb, 'answered', null, null);
  perform public.mirror_answer_save('dimension_relationships', 'cg_custody', '"yes"'::jsonb, 'answered', null, null);
  perform public.mirror_answer_save('dimension_mental_health', 'su_use', '"recovery"'::jsonb, 'answered', null, null);
  perform public.mirror_answer_save('dimension_self_care', 'cl_needs', '["under","outer"]'::jsonb, 'answered', null, null);
  j := public.mirror_set_get('dimension_relationships', null);
  ok := (select e -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') e where e ->> 'key' = 'cg_custody') is not null;   -- the person sees all
  perform set_config('request.jwt.claims', jc, true);
  j := public.mirror_set_get('dimension_relationships', pv);
  ok := ok and (select e -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') e where e ->> 'key' = 'cg_children') = 'with_me'
    and (select (e ->> 'hidden')::boolean and e -> 'answer' = 'null'::jsonb from jsonb_array_elements(j -> 'questions') e where e ->> 'key' = 'cg_custody');
  begin perform public.mirror_set_get('dimension_mental_health', pv); ok := false; exception when insufficient_privilege then null; end;
  j := public.mirror_set_get('dimension_self_care', pv);
  ok := ok and (select e -> 'answer' -> 'value' from jsonb_array_elements(j -> 'questions') e where e ->> 'key' = 'cl_needs') = '["outer","under"]'::jsonb;   -- multi answers are stored sorted
  execute 'reset role';
  r := r || format('3 answers save; coordinator sees children and clothing needs, never custody or substance use without sharing: %s', ok);

  -- 4. a topic's own help question becomes a named suggested need
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jv, true);
  perform public.mirror_answer_save('dimension_mental_health', 'su_help', '"now"'::jsonb, 'answered', null, null);
  perform public.mirror_answer_save('dimension_relationships', 'cg_help', '"later"'::jsonb, 'answered', null, null);
  perform public.mirror_answer_save('dimension_housing', 'hf_help', '"no"'::jsonb, 'answered', null, null);
  execute 'reset role';
  ok := exists (select 1 from mirror.need_suggestions_for(pv) x where x.title = 'Help with: treatment or recovery support' and x.urgency = 'soon' and x.dimension_key = 'mental_health')
    and exists (select 1 from mirror.need_suggestions_for(pv) x where x.title = 'Help with: childcare or caregiving' and x.urgency = 'later' and x.dimension_key = 'relationships')
    and not exists (select 1 from mirror.need_suggestions_for(pv) x where x.title like '%furniture%');
  r := r || format('4 topic help answers become named suggested needs (now = soon, later = later, no = none): %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
