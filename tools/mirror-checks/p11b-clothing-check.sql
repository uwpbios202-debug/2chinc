-- Mirror Phase 11 T11.1 check: clothing, laundry and garment care (migration 20261119701000). Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; o2 uuid; pv uuid; pn uuid; ok boolean; j jsonb;
  uv uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); sv uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sb uuid := gen_random_uuid();
  jv text; jc text; jb text;
begin
  insert into auth.users (id, email) values (uv, 'check.kv@example.invalid'), (uc, 'check.kc@example.invalid'), (ub, 'check.kb@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sv, uv, now(), now(), now(), 'aal1'), (sc, uc, now(), now(), now(), 'aal2'),
    (sb, ub, now(), now(), now(), 'aal2');
  jv := json_build_object('sub', uv, 'email', 'check.kv@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sv)::text;
  jc := json_build_object('sub', uc, 'email', 'check.kc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  jb := json_build_object('sub', ub, 'email', 'check.kb@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sb)::text;
  insert into mirror.organizations (name, kind) values ('CHECK clothing org', 'nonprofit') returning id into o;
  insert into mirror.organizations (name, kind) values ('CHECK clothing other org', 'nonprofit') returning id into o2;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.kc@example.invalid', 'CHECK KC', 'coordinator'),
    (o2, 'check.kb@example.invalid', 'CHECK KB', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.kv@example.invalid', 'CHECK KV', o) returning id into pv;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values (null, 'CHECK KN', o) returning id into pn;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (o, pv, 'active', current_date), (o, pn, 'active', current_date);
  insert into mirror.consents (individual_id, organization_id, category, granted_by, access, method) values
    (pv, o, 'general', 'check.kv@example.invalid', 'edit', 'online'), (pn, o, 'general', 'check.kc@example.invalid', 'edit', 'paper');   -- "see and change"
  insert into mirror.inventory_items (organization_id, category, item, size, condition, season, quantity, created_by) values
    (o, 'coats', 'CHECK winter coat L', 'L', 'good', 'winter', 2, 'check'), (o, 'coats', 'CHECK winter coat XL', 'XL', 'good', 'winter', 1, 'check'),
    (o, 'clothing', 'CHECK socks pack', null, 'new', 'all', 5, 'check'), (o2, 'coats', 'CHECK other org coat L', 'L', 'good', 'winter', 1, 'check');

  -- 1. the person: counts and sizes saved; suggested numbers follow how often they can do laundry
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jv, true);
  j := public.mirror_clothing_get(null);
  ok := (select (e ->> 'suggested')::int from jsonb_array_elements(j -> 'items') e where e ->> 'category' = 'under') = 10 and (j ->> 'laundry_days')::int = 7;
  perform public.mirror_answer_save('dimension_self_care', 'cl_laundry_often', '"two_weeks"'::jsonb, 'answered', null, null);
  perform public.mirror_answer_save('dimension_self_care', 'cl_laundry_access', '"none"'::jsonb, 'answered', null, null);
  j := public.mirror_clothing_save(jsonb_build_object('items', jsonb_build_array(
         jsonb_build_object('category', 'under', 'usable', 2, 'want', 10), jsonb_build_object('category', 'outer', 'usable', 0, 'want', 1),
         jsonb_build_object('category', 'socks', 'usable', 1, 'want', 8), jsonb_build_object('category', 'tops', 'usable', 7, 'want', 7, 'needs_fixing', 2)),
         'sizes', jsonb_build_object('top', 'M', 'coat', 'L', 'nonsense', 'x'), 'storage', '["closet"]'::jsonb, 'skills', '["wash","fold"]'::jsonb), null);
  ok := ok and (select (e ->> 'suggested')::int from jsonb_array_elements(j -> 'items') e where e ->> 'category' = 'under') = 17
    and (j -> 'profile' -> 'sizes') = '{"top": "M", "coat": "L"}'::jsonb and not (j -> 'profile' ->> 'sizes_shared')::boolean
    and (select (e ->> 'needs_fixing')::int from jsonb_array_elements(j -> 'items') e where e ->> 'category' = 'tops') = 2
    and (j -> 'matches') = '[]'::jsonb;
  execute 'reset role';
  r := r || format('1 person saves counts and sizes (unknown size keys dropped); suggested numbers follow laundry (10 weekly, 17 every 2 weeks): %s', ok);

  -- 2. gaps and no place to do laundry become suggested needs
  ok := exists (select 1 from mirror.need_suggestions_for(pv) x where x.title = 'Clothes: underwear and bras (8 more)' and x.urgency = 'later' and x.dimension_key = 'self_care')
    and exists (select 1 from mirror.need_suggestions_for(pv) x where x.title = 'Clothes: a coat or jacket (1 more)' and x.urgency = 'soon')
    and exists (select 1 from mirror.need_suggestions_for(pv) x where x.title = 'A reliable way to do laundry')
    and not exists (select 1 from mirror.need_suggestions_for(pv) x where x.title like 'Clothes: everyday tops%');
  r := r || format('2 gaps and no laundry become suggested needs (no gap, no suggestion): %s', ok);

  -- 3. the coordinator: sees the counts, not the sizes; matches only size-free items; after the person shares sizes, the coat in their size
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  j := public.mirror_clothing_get(pv);
  ok := (j -> 'profile' -> 'sizes') = 'null'::jsonb
    and (select (e ->> 'usable')::int from jsonb_array_elements(j -> 'items') e where e ->> 'category' = 'under') = 2
    and exists (select 1 from jsonb_array_elements(j -> 'matches') e where e ->> 'item' = 'CHECK socks pack')
    and not exists (select 1 from jsonb_array_elements(j -> 'matches') e where e ->> 'item' like 'CHECK winter coat%');
  perform public.mirror_clothing_save(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('category', 'socks', 'usable', 3, 'want', 8)),
    'sizes', jsonb_build_object('top', 'XXL'), 'sizes_shared', true), pv);
  perform set_config('request.jwt.claims', jv, true);
  j := public.mirror_clothing_get(null);
  ok := ok and (j -> 'profile' -> 'sizes' ->> 'top') = 'M' and not (j -> 'profile' ->> 'sizes_shared')::boolean
    and (select (e ->> 'usable')::int from jsonb_array_elements(j -> 'items') e where e ->> 'category' = 'socks') = 3;
  perform public.mirror_clothing_save(jsonb_build_object('sizes', jsonb_build_object('top', 'M', 'coat', 'L'), 'sizes_shared', true), null);
  perform set_config('request.jwt.claims', jc, true);
  j := public.mirror_clothing_get(pv);
  ok := ok and (j -> 'profile' -> 'sizes' ->> 'coat') = 'L'
    and exists (select 1 from jsonb_array_elements(j -> 'matches') e where e ->> 'item' = 'CHECK winter coat L' and e ->> 'for' = 'outer')
    and not exists (select 1 from jsonb_array_elements(j -> 'matches') e where e ->> 'item' in ('CHECK winter coat XL', 'CHECK other org coat L'));
  execute 'reset role';
  r := r || format('3 coordinator: counts yes, sizes only when shared (cannot share for them), matches by size in their own organization: %s', ok);

  -- 4. a person without a sign-in: the coordinator records that they agreed to share sizes
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  j := public.mirror_clothing_save(jsonb_build_object('sizes', jsonb_build_object('shoe', '10'), 'sizes_agreed', false), pn);
  ok := (j -> 'profile' -> 'sizes') = 'null'::jsonb;
  j := public.mirror_clothing_save(jsonb_build_object('sizes', jsonb_build_object('shoe', '10'), 'sizes_agreed', true), pn);
  ok := ok and (j -> 'profile' -> 'sizes' ->> 'shoe') = '10' and (j -> 'profile' ->> 'sizes_shared')::boolean;
  -- 5. another organization (no link) is refused
  perform set_config('request.jwt.claims', jb, true);
  begin perform public.mirror_clothing_get(pv); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_clothing_save('{}'::jsonb, pv); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  r := r || format('4 no sign-in: sizes only with recorded agreement; 5 an organization not working with them is refused: %s', ok);

  -- 6. closed to the API roles; deleted with the person
  ok := not has_table_privilege('authenticated', 'mirror.clothing_items', 'select') and not has_table_privilege('anon', 'mirror.clothing_profiles', 'select')
    and not has_function_privilege('anon', 'public.mirror_clothing_get(uuid)', 'execute') and not has_function_privilege('anon', 'public.mirror_clothing_save(jsonb, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.laundry_days(uuid)', 'execute');
  delete from mirror.individuals where id = pv;
  ok := ok and not exists (select 1 from mirror.clothing_items where individual_id = pv) and not exists (select 1 from mirror.clothing_profiles where individual_id = pv);
  r := r || format('6 closed to anon and authenticated; deleted with the person: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
