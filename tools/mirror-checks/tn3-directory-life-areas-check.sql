-- Phase N TN.3 check: the resource directory by life area (part A) and the researched non-housing programs (part B).
-- A made-up office staff member, Navigator and person; always rolled back.
do $chk$
declare
  r text[] := '{}'; j jsonb; ok boolean; n int; a uuid; h uuid; pr text;
  us uuid := gen_random_uuid(); un uuid := gen_random_uuid(); ua uuid := gen_random_uuid();
  ss uuid := gen_random_uuid(); sn uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); js text; jn text; ja text; x uuid;
begin
  insert into auth.users (id, email) values (us, 'check.os@example.invalid'), (un, 'check.on@example.invalid'), (ua, 'check.op@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values
    (ss, us, now(), now(), now(), 'aal2'), (sn, un, now(), now(), now(), 'aal1'), (sa, ua, now(), now(), now(), 'aal1');
  js := json_build_object('sub', us, 'email', 'check.os@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', ss)::text;
  jn := json_build_object('sub', un, 'email', 'check.on@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sn)::text;
  ja := json_build_object('sub', ua, 'email', 'check.op@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  insert into condo_staff (email, name) values ('check.os@example.invalid', 'CHECK OS');
  insert into navigators (name, email, status) values ('CHECK ON', 'check.on@example.invalid', 'pilot');
  select program_id into pr from chpms_programs where program_id = 'PRG048';   -- a housing program with rule links

  -- 1. part B rows: 8 organizations, 10 programs, 10 sources; every program cites existing sources and has a life area; nothing pays money
  ok := (select count(*) from chpms_orgs where import_version = 'tn3-11/13' and is_local) = 8
    and (select count(*) from chpms_programs where import_version = 'tn3-11/13' and is_local) = 10
    and (select count(*) from chpms_sources where source_id like 'TN3-S%') = 10
    and not exists (select 1 from chpms_programs p where p.import_version = 'tn3-11/13'
                    and (p.is_direct_financial or exists (select 1 from unnest(string_to_array(p.source_ids, ';')) s where not exists (select 1 from chpms_sources c where c.source_id = s))
                         or not exists (select 1 from mirror.resource_categories c where c.chpms_program_id = p.program_id and c.source = 'office')))
    and not exists (select 1 from chpms_programs where import_version = 'tn3-11/13' and verification_status not in ('Verified – Current', 'Verified – Limited'));
  r := r || format('1 8 organizations, 10 programs, 10 sources; cited, tagged, none pays money: %s', ok);

  -- 2. the 15 areas and each program's areas, for a Navigator too; only office staff may tag
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jn, true);
  j := public.chpms_life_areas();
  ok := jsonb_array_length(j -> 'areas') = 15 and not (j ->> 'can_tag')::boolean
    and (j -> 'links' -> 'TN3-PRG03') ? 'food' and (j -> 'links' -> 'TN3-PRG03') ? 'finances' and not (j -> 'by_rule') ? 'TN3-PRG03'
    and (j -> 'links' -> 'PRG048') ? 'housing';
  begin perform public.chpms_program_areas_save('TN3-PRG04', array['food', 'safety']); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', ja, true);
  begin perform public.chpms_life_areas(); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('2 a Navigator reads the 15 areas and links, cannot tag; someone else cannot read: %s', ok);

  -- 3. office staff tag: an office area is added; housing (from the help types) stays when removed from the list; unknown area refused
  perform set_config('request.jwt.claims', js, true);
  j := public.chpms_life_areas();
  ok := (j ->> 'can_tag')::boolean;
  j := public.chpms_program_areas_save(pr, array['housing', 'identity_legal', 'safety']);
  ok := ok and (j -> 'links' -> pr) ? 'safety';
  j := public.chpms_program_areas_save(pr, array['identity_legal']);
  ok := ok and not (j -> 'links' -> pr) ? 'safety' and (j -> 'links' -> pr) ? 'housing';
  begin perform public.chpms_program_areas_save(pr, array['not_an_area']); ok := false; exception when invalid_parameter_value then null; end;
  r := r || format('3 office staff tag and untag; help-type areas stay; unknown area refused: %s', ok);

  -- 4. the Mirror finds them: a person with a food need sees a TN.3 program among the matches ("Help I could get", T7.2)
  execute 'reset role';
  insert into mirror.individuals (auth_email, preferred_name) values ('check.op@example.invalid', 'CHECK OP') returning id into a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  h := (public.mirror_need_save(null, 'food', 'Enough food for the week', null, 'urgent') ->> 'id')::uuid;
  j := public.mirror_resources();
  select count(*) into n from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p where p ->> 'program_id' like 'TN3-PRG%';
  ok := n >= 1;
  r := r || format('4 a food need in the Mirror is matched to %s TN.3 programs: %s', n, ok);

  -- 5. closed to anon
  execute 'reset role';
  ok := not has_function_privilege('anon', 'public.chpms_life_areas()', 'execute') and not has_function_privilege('anon', 'public.chpms_program_areas_save(text, text[])', 'execute');
  r := r || format('5 closed to anon: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
