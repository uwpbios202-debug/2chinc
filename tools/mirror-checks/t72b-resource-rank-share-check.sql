-- Mirror T7.2 follow-up check: every match ranked (no limit), reasons shown; place and groups shared only by the person's choice.
-- Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; j jsonb; k jsonb; n int; m int; ok boolean; h uuid;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; cx text; vet text;
begin
  insert into auth.users (id, email) values (ua, 'check.ka@example.invalid'), (uc, 'check.kcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ka@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.kcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ka@example.invalid', 'CHECK KA') returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.kcx@example.invalid', 'CHECK KCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  -- how many housing programs the directory could offer (not do-not-refer)
  select count(distinct rc.chpms_program_id) into m from mirror.resource_categories rc
    join public.chpms_programs p on p.program_id = rc.chpms_program_id join public.chpms_orgs o on o.org_id = p.org_id
   where rc.dimension_key = 'housing' and coalesce(o.our_relationship, '') <> 'do_not_refer';
  select pp.program_id into vet from public.chpms_program_pops pp where pp.population = 'Veterans'
     and exists (select 1 from mirror.resource_categories rc where rc.chpms_program_id = pp.program_id and rc.dimension_key = 'housing') limit 1;
  perform set_config('role', 'authenticated', true);

  -- 1. no limit: every housing program comes back, ranks 1..n in order, scores never go up, every program has reasons
  perform set_config('request.jwt.claims', pa, true);
  h := (public.mirror_need_save(null, 'housing', 'A place of my own', null, 'urgent') ->> 'id')::uuid;
  j := public.mirror_resources() -> 'matches' -> 0 -> 'programs';
  n := jsonb_array_length(j);
  ok := n = m
    and not exists (select 1 from jsonb_array_elements(j) with ordinality e(p, i) where (p ->> 'rank')::int <> i)
    and not exists (select 1 from jsonb_array_elements(j) with ordinality e(p, i) join jsonb_array_elements(j) with ordinality f(q, i2) on i2 = i + 1
                     where (q ->> 'score')::int > (p ->> 'score')::int)
    and not exists (select 1 from jsonb_array_elements(j) e where jsonb_typeof(e -> 'why') <> 'array' or jsonb_array_length(e -> 'why') = 0)
    and not exists (select 1 from jsonb_array_elements(j) e where (e ->> 'score')::int <> coalesce((select sum((w ->> 'points')::int) from jsonb_array_elements(e -> 'why') w), 0));
  r := r || format('1 all %s housing programs returned (directory has %s), ranked 1..n, best fit first, reasons add up to the score: %s', n, m, ok);

  -- 2. saying "veteran" moves a veterans' program up and says why
  k := (select e from jsonb_array_elements(j) e where e ->> 'program_id' = vet);
  perform public.mirror_resource_profile_save(null, array['Veterans']);
  j := public.mirror_resources() -> 'matches' -> 0 -> 'programs';
  ok := vet is not null
    and (select (e ->> 'rank')::int from jsonb_array_elements(j) e where e ->> 'program_id' = vet) < (k ->> 'rank')::int
    and exists (select 1 from jsonb_array_elements(j) e, jsonb_array_elements(e -> 'why') w where e ->> 'program_id' = vet and w ->> 'reason' ilike '%veterans%fits you%');
  r := r || format('2 a veterans program rises from rank %s to %s with the reason shown: %s', k ->> 'rank',
                   (select e ->> 'rank' from jsonb_array_elements(j) e where e ->> 'program_id' = vet), ok);

  -- 3. not shared (default): a coordinator with sharing sees no place or groups; shared: sees them, read-only, and the order uses them
  perform public.mirror_resource_profile_save('milwaukee_city', array['Veterans']);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_resources(a);
  ok := j -> 'profile' = 'null'::jsonb and j -> 'household_groups' = 'null'::jsonb
    and not exists (select 1 from jsonb_array_elements(j -> 'matches' -> 0 -> 'programs') e, jsonb_array_elements(e -> 'why') w where w ->> 'reason' ilike '%fits you%');
  begin perform public.mirror_resource_profile_save('outside', null, true); ok := ok and false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  k := public.mirror_resource_profile_save('milwaukee_city', array['Veterans'], true);
  ok := ok and (k ->> 'shared')::boolean;
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_resources(a);
  ok := ok and j -> 'profile' ->> 'place' = 'milwaukee_city' and (j -> 'profile' ->> 'shared')::boolean and j -> 'profile' -> 'groups' ? 'Veterans'
    and exists (select 1 from jsonb_array_elements(j -> 'matches' -> 0 -> 'programs') e, jsonb_array_elements(e -> 'why') w where w ->> 'reason' ilike '%veterans%fits you%');
  r := r || format('3 not shared: coordinator sees no place/groups and cannot set them; shared by the person: sees them and the order uses them: %s', ok);

  -- 4. the person takes sharing back; a later save without the choice keeps it as it is; the download says whether it is shared
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_resource_profile_save('milwaukee_city', array['Veterans'], false);
  perform public.mirror_resource_profile_save('milwaukee_county', array['Veterans']);
  k := public.mirror_my_export_resources() -> 'where_and_groups';
  ok := k ->> 'place' = 'milwaukee_county' and not (k ->> 'shared_with_organizations')::boolean;
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and public.mirror_resources(a) -> 'profile' = 'null'::jsonb;
  execute 'reset role';
  ok := ok and not has_function_privilege('anon', 'public.mirror_resource_profile_save(text, text[], boolean)', 'execute')
     and not has_function_privilege('authenticated', 'mirror.resource_matches(uuid, boolean)', 'execute')
     and not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                      where s.nspname = 'public' and p.proname = 'mirror_resource_profile_save' and p.pronargs = 2);
  r := r || format('4 sharing taken back hides it again; save without the choice keeps it; download shows it; old 2-argument function gone: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
