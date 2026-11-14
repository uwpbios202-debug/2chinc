-- Mirror T7.1 check: CHPMS programs linked to areas of life and Daily Number cost categories. Always rolled back.
-- Uses a made-up program (CHECK-T71) so no real directory row is changed, even inside the rolled-back transaction.
do $chk$
declare
  r text[] := '{}'; n int; m int; ok boolean; j jsonb; o text;
begin
  -- 1. closed to browsers: row security on, no grants to anon / authenticated / PUBLIC, helpers not executable by them
  ok := (select bool_and(c.relrowsecurity) from pg_class c join pg_namespace s on s.oid = c.relnamespace
          where s.nspname = 'mirror' and c.relname in ('resource_categories', 'resource_assist_map'))
    and not has_table_privilege('authenticated', 'mirror.resource_categories', 'select')
    and not has_table_privilege('anon', 'mirror.resource_categories', 'select')
    and not has_table_privilege('authenticated', 'mirror.resource_assist_map', 'select')
    and not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'mirror'
                     and g.table_name in ('resource_categories', 'resource_assist_map') and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
    and not has_function_privilege('authenticated', 'mirror.resource_categories_refresh()', 'execute')
    and not has_function_privilege('anon', 'mirror.program_areas(text)', 'execute');
  r := r || format('1 tables have row security, no browser grants, helpers closed: %s', ok);

  -- 2. first fill: every live program with a mapped help type has a link; no 'rule' link on a program without one. Office links (set by hand,
  --    e.g. the TN.3 non-housing programs, migration 20261119631000) may sit on programs without help types: that is by design.
  select count(*) into n from public.chpms_programs p
   where exists (select 1 from public.chpms_program_assist a join mirror.resource_assist_map mm on mm.assist_category = a.category
                  where a.program_id = p.program_id and a.provided)
     and not exists (select 1 from mirror.resource_categories rc where rc.chpms_program_id = p.program_id);
  select count(*) into m from mirror.resource_categories rc
   where rc.source = 'rule' and not exists (select 1 from public.chpms_program_assist a where a.program_id = rc.chpms_program_id and a.provided);
  ok := n = 0 and m = 0 and not exists (select 1 from mirror.resource_categories where source not in ('rule', 'office'));
  select count(*) into n from mirror.resource_categories;
  select count(distinct chpms_program_id) into m from mirror.resource_categories;
  r := r || format('2 first fill: %s links on %s programs, none missing, no rule link without a help type: %s', n, m, ok);

  -- 3. every help type the CHPMS check constraint allows is in the map (so nothing is silently left out)
  select count(*), string_agg(t, ', ') filter (where not exists (select 1 from mirror.resource_assist_map mm where mm.assist_category = t))
    into m, o
    from (select replace(x[1], '''''', '''') t
            from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint where conname = 'chpms_program_assist_category_check'),
                                '''((?:[^'']|'''')+)''::text', 'g') x) allowed;
  select count(distinct assist_category) into n from mirror.resource_assist_map;
  r := r || format('3 CHPMS allows %s help types, map covers %s; allowed types without a map row: %s', m, n, coalesce(o, 'none'));

  -- 4. a new program with help types gets its links by itself (the import trigger); a help type marked not provided adds nothing
  insert into public.chpms_programs (program_id, org_id, program_name)
    select 'CHECK-T71', org_id, 'CHECK program' from public.chpms_orgs limit 1;
  insert into public.chpms_program_assist (program_id, category, provided) values
    ('CHECK-T71', 'Utility assistance', true), ('CHECK-T71', 'Eviction prevention', true),
    ('CHECK-T71', 'Security deposit assistance', false);
  j := mirror.program_areas('CHECK-T71');
  ok := jsonb_array_length(j) = 3
    and j @> '[{"area": "housing", "cost": "utilities"}, {"area": "housing", "cost": "housing"}, {"area": "identity_legal", "cost": null}]'::jsonb
    and j -> 0 ->> 'area' = 'housing';
  -- a map row removed: the next import adds no link for it and does not fail
  delete from mirror.resource_assist_map where assist_category = 'Utility assistance';
  update public.chpms_program_assist set provided = true where program_id = 'CHECK-T71' and category = 'Utility assistance';
  ok := ok and jsonb_array_length(mirror.program_areas('CHECK-T71')) = 2;
  insert into mirror.resource_assist_map values ('Utility assistance', 'housing', 'utilities');
  perform mirror.resource_categories_refresh();
  r := r || format('4 new program linked by the trigger (3 links, not-provided ignored, unmapped type adds nothing): %s %s', ok, j::text);

  -- 5. an office link survives a refresh and a re-import; rule links follow the help types (delete + re-insert, as the import does)
  insert into mirror.resource_categories (chpms_program_id, dimension_key, source, added_by, note)
    values ('CHECK-T71', 'work', 'office', 'check@example.invalid', 'CHECK office tag');
  delete from public.chpms_program_assist where program_id = 'CHECK-T71';
  ok := (select count(*) from mirror.resource_categories where chpms_program_id = 'CHECK-T71') = 1
    and exists (select 1 from mirror.resource_categories where chpms_program_id = 'CHECK-T71' and source = 'office');
  insert into public.chpms_program_assist (program_id, category, provided) values ('CHECK-T71', 'Financial counseling', true);
  perform mirror.resource_categories_refresh();
  ok := ok and (select count(*) from mirror.resource_categories where chpms_program_id = 'CHECK-T71') = 2
    and exists (select 1 from mirror.resource_categories where chpms_program_id = 'CHECK-T71' and dimension_key = 'finances'
                 and expense_category_key = 'financial' and source = 'rule');
  r := r || format('5 office link kept through delete + re-insert + refresh; rule links follow: %s', ok);

  -- 6. one row per program + area + cost (also when the cost is empty); removing the program removes its links; no bulk emptying
  begin
    insert into mirror.resource_categories (chpms_program_id, dimension_key, source) values ('CHECK-T71', 'work', 'office');
    ok := false;
  exception when unique_violation then ok := true; end;
  delete from public.chpms_program_assist where program_id = 'CHECK-T71';
  delete from public.chpms_programs where program_id = 'CHECK-T71';
  ok := ok and not exists (select 1 from mirror.resource_categories where chpms_program_id = 'CHECK-T71');
  begin
    truncate mirror.resource_categories;
    ok := false;
  exception when insufficient_privilege then null; end;
  r := r || format('6 no duplicate link (empty cost too); program removal removes its links; truncate refused: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
