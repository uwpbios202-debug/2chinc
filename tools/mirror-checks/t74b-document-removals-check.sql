-- Mirror T7.4 follow-up check: a person's files never outlive their details. Fictional people; always rolled back.
-- Files are simulated by storage.objects rows; "removed" by renaming the row (the real removal is the Storage API in mirror-files).
do $chk$
declare
  r text[] := '{}'; a uuid; d1 uuid; d2 uuid; p1 text; p2 text; px text; ok boolean; n int;
  ua uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); pa text;
begin
  insert into auth.users (id, email) values (ua, 'check.ha@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sa, ua, now(), now(), now(), 'aal1');
  pa := json_build_object('sub', ua, 'email', 'check.ha@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ha@example.invalid', 'CHECK HA') returning id into a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  d1 := (public.mirror_document_begin(null, 'state_id', null, 'a.jpg', 'image/jpeg', 10, null, null) ->> 'id')::uuid;
  d2 := (public.mirror_document_begin(null, 'lease', null, 'b.pdf', 'application/pdf', 10, null, null) ->> 'id')::uuid;
  execute 'reset role';
  select storage_path into p1 from mirror.documents where id = d1;
  select storage_path into p2 from mirror.documents where id = d2;
  insert into storage.objects (bucket_id, name) values ('mirror-docs', p1), ('mirror-docs', p2);
  px := 'check-stray/' || gen_random_uuid()::text;
  insert into storage.objects (bucket_id, name, created_at) values ('mirror-docs', px, now() - interval '2 days');

  -- 1. nothing queued while details exist; only the day-old stray file is listed
  ok := not exists (select 1 from mirror.document_removals where path in (p1, p2))
    and not exists (select 1 from public.mirror_document_sweep_list() x where x in (p1, p2))
    and exists (select 1 from public.mirror_document_sweep_list() x where x = px) and mirror.document_sweep_needed();
  r := r || format('1 files with details are never listed; a stray day-old file is: %s', ok);

  -- 2. removing the person removes their details and queues both files
  delete from mirror.individuals where id = a;
  ok := (select count(*) from mirror.document_removals where path in (p1, p2)) = 2
    and (select count(*) from public.mirror_document_sweep_list() x where x in (p1, p2, px)) = 3;
  r := r || format('2 person removed: both files queued for removal: %s', ok);

  -- 3. once the files are gone, the queue clears and nothing waits
  update storage.objects set name = name || '-removed' where bucket_id = 'mirror-docs' and name in (p1, p2, px);
  select public.mirror_document_sweep_done() into n;
  ok := not exists (select 1 from mirror.document_removals where path in (p1, p2))
    and not exists (select 1 from public.mirror_document_sweep_list() x where x in (p1, p2, px));
  r := r || format('3 after removal the queue clears (%s other waiting): %s', n, ok);

  -- 4. closed to browsers; the job exists and carries no secret in plain sight here (only checked that it calls mirror-files)
  ok := not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'mirror' and g.table_name = 'document_removals'
                    and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
    and not has_function_privilege('authenticated', 'public.mirror_document_sweep_list()', 'execute')
    and not has_function_privilege('anon', 'public.mirror_document_sweep_done()', 'execute')
    and exists (select 1 from cron.job where jobname = 'mirror-docs-sweep' and schedule = '17 * * * *' and command like '%functions/v1/mirror-files%'
                and command like '%x-cycle-secret%');
  r := r || format('4 closed to browsers; hourly job calls mirror-files: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
