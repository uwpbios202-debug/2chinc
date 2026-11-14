-- Mirror database #3 check: Milwaukee Cost-of-Living Benchmarks (migrations 20261119750000 + 20261119751000). Fictional sign-in; always rolled back.
-- Run: cat both migrations into one file, then sh ./.claude-tools/mirror-rollback-check.sh <that file> tools/mirror-checks/col-cost-benchmarks-check.sql
do $chk$
declare
  r text[] := '{}'; ok boolean; j jsonb; n int; want int;
  ua uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); pa text;
begin
  insert into auth.users (id, email) values (ua, 'check.col@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.col@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;

  -- 1. the data: 144 benchmarks in the 12 categories and 3 levels, 28 sources (every source id used exists), 5 examples, 7 conflicts
  ok := (select count(*) from mirror.cost_benchmarks) = 144 and (select count(*) from mirror.cost_benchmark_sources) = 28
    and (select count(*) from mirror.cost_benchmark_examples) = 5 and (select count(*) from mirror.cost_benchmark_conflicts) = 7
    and (select count(distinct category) from mirror.cost_benchmarks) = 12
    and not exists (select 1 from mirror.cost_benchmarks b, unnest(b.source_ids) s where not exists (select 1 from mirror.cost_benchmark_sources x where x.source_id = s))
    and (select amount_as_published from mirror.cost_benchmarks where benchmark_id = 'COL-002') = 1027
    and (select verification_status from mirror.cost_benchmarks where benchmark_id = 'COL-007') = 'Needs Confirmation';
  r := r || format('1 144 benchmarks, 12 categories, 28 sources all found, 5 examples, 7 conflicts; FY2026 rent in effect, FY2027 marked: %s', ok);

  -- 2. the 1-adult stability example adds up from its rows (yearly figures)
  ok := (select abs(sum(b.per_year) - 36513) < 1 from mirror.cost_benchmarks b where b.benchmark_id = any ((select benchmark_ids from mirror.cost_benchmark_examples where id = 1)::text[]));
  r := r || format('2 the 1-adult stability example adds to $36,513 a year: %s', ok);

  select count(*) into want from mirror.cost_benchmarks where verification_status like 'Verified%' and amount_as_published is not null;
  -- 3. not signed in: refused
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', '{}', true);
  ok := false;
  begin perform public.mirror_cost_benchmarks(); exception when others then ok := true; end;
  r := r || format('3 refused without a sign-in: %s', ok);

  -- 4. a signed-in person: only Verified rows with a figure, no conflicts
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_cost_benchmarks();
  select count(*) into n from jsonb_array_elements(j -> 'rows') e;
  ok := not (j ->> 'office')::boolean and n = want
    and not exists (select 1 from jsonb_array_elements(j -> 'rows') e where e ->> 'status' not like 'Verified%')
    and jsonb_array_length(j -> 'conflicts') = 0 and j -> 'sources' ? 'COL-S01';
  r := r || format('4 a person sees %s verified rows only, no conflicts: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
