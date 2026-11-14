-- Mirror T7.4 check: documents in the private bucket mirror-docs, through the gate. Fictional people; always rolled back.
-- A file "arriving" is simulated by a storage.objects row (what the Storage API writes after a signed upload); "removing" it by renaming
-- that row (the real removal goes through the Storage API in mirror-files). Nothing is uploaded and nothing is kept.
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; b uuid; j jsonb; k jsonb; n int; ok boolean; d1 uuid; d2 uuid; p1 text; p2 text;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; pb text; cx text;
begin
  insert into auth.users (id, email) values (ua, 'check.ga@example.invalid'), (ub, 'check.gb@example.invalid'), (uc, 'check.gcx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values
    (sa, ua, now(), now(), now(), 'aal1'), (sb, ub, now(), now(), now(), 'aal1'), (sc, uc, now(), now(), now(), 'aal2');
  pa := json_build_object('sub', ua, 'email', 'check.ga@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.gb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.gcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ga@example.invalid', 'CHECK GA') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.gb@example.invalid', 'CHECK GB') returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.gcx@example.invalid', 'CHECK GCX', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');

  -- 1. the bucket is private with no storage policy at all; the tables are closed to browsers
  ok := (select not public and file_size_limit = 10485760 from storage.buckets where id = 'mirror-docs')
    and not exists (select 1 from pg_policies where schemaname = 'storage' and (coalesce(qual, '') ~ 'mirror.docs' or coalesce(with_check, '') ~ 'mirror.docs'))
    and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and coalesce(qual, '') !~ 'bucket_id' and coalesce(with_check, '') !~ 'bucket_id')
    and not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'mirror'
                    and g.table_name in ('documents', 'document_types') and g.grantee in ('anon', 'authenticated', 'PUBLIC'))
    and not has_function_privilege('anon', 'public.mirror_document_open(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.document_file_exists(text)', 'execute')
    and (select count(*) from mirror.document_types) = 8;
  r := r || format('1 bucket private, no storage policy, tables and helpers closed, 8 types: %s', ok);

  -- 2. the person starts an upload; it shows only once the file is there; wrong kind / too big refused
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  k := public.mirror_document_begin(null, 'state_id', 'My ID', 'id front.jpg', 'image/jpeg', 120000, date '2029-05-01', 'In the blue folder');
  d1 := (k ->> 'id')::uuid; p1 := k ->> 'path';
  ok := p1 = a::text || '/' || d1::text and jsonb_array_length(public.mirror_documents() -> 'list') = 0;
  begin perform public.mirror_document_begin(null, 'other', null, 'x.exe', 'application/x-msdownload', 10, null, null); ok := false;
  exception when invalid_parameter_value then null; end;
  begin perform public.mirror_document_begin(null, 'other', null, 'big.pdf', 'application/pdf', 10485761, null, null); ok := false;
  exception when invalid_parameter_value then null; end;
  execute 'reset role';
  insert into storage.objects (bucket_id, name, metadata) values ('mirror-docs', p1, jsonb_build_object('size', 120000, 'mimetype', 'image/jpeg'));
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_documents();
  ok := ok and jsonb_array_length(j -> 'list') = 1 and j -> 'list' -> 0 ->> 'expires_on' = '2029-05-01' and (j -> 'list' -> 0 ->> 'can_delete')::boolean
    and public.mirror_document_open(d1) ->> 'path' = p1;
  -- a type without an expiry date keeps none
  k := public.mirror_document_update(d1, 'birth_certificate', 'Birth certificate', date '2030-01-01', null);
  ok := ok and k ->> 'expires_on' is null and k ->> 'type' = 'birth_certificate';
  k := public.mirror_document_update(d1, 'state_id', 'My ID', date '2029-05-01', 'In the blue folder');
  r := r || format('2 person uploads; shown only once the file exists; bad kind and >10 MB refused; details editable: %s', ok);

  -- 3. coordinator without consent for Documents: nothing (no list, no open, no upload)
  perform set_config('request.jwt.claims', cx, true);
  ok := true;
  begin perform public.mirror_documents(a); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_document_open(d1); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_document_begin(a, 'other', null, 'a.pdf', 'application/pdf', 10, null, null); ok := false;
  exception when insufficient_privilege then null; end;
  r := r || format('3 coordinator without consent: no list, open or upload: %s', ok);

  -- 4. with "can see": list and open (logged in the person's who-looked), still no upload
  execute 'reset role';
  insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (a, x, 'documents', 'view', 'check.ga@example.invalid');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_documents(a);
  ok := jsonb_array_length(j -> 'list') = 1 and not (j -> 'list' -> 0 ->> 'can_delete')::boolean and public.mirror_document_open(d1) ->> 'path' = p1;
  begin perform public.mirror_document_begin(a, 'other', null, 'a.pdf', 'application/pdf', 10, null, null); ok := false;
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and exists (select 1 from mirror.audit_logs where individual_id = a and actor_email = 'check.gcx@example.invalid' and action = 'view'
                        and table_name = 'documents' and row_id = d1::text);
  r := r || format('4 coordinator with "can see": lists and opens (logged), cannot upload: %s', ok);

  -- 5. with "see and change": adds one; may delete only their own; delete refused while the file exists; then gone
  update mirror.consents set access = 'edit' where individual_id = a and organization_id = x and category = 'documents';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  k := public.mirror_document_begin(a, 'lease', null, 'lease.pdf', 'application/pdf', 5000, null, null);
  d2 := (k ->> 'id')::uuid; p2 := k ->> 'path';
  ok := true;
  begin perform public.mirror_document_delete_check(d1); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  insert into storage.objects (bucket_id, name) values ('mirror-docs', p2);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and public.mirror_document_delete_check(d2) ->> 'path' = p2;
  begin perform public.mirror_document_delete(d2); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  update storage.objects set name = name || '-removed' where bucket_id = 'mirror-docs' and name = p2;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', cx, true);
  ok := ok and public.mirror_document_delete(d2);
  perform set_config('request.jwt.claims', pa, true);
  ok := ok and jsonb_array_length(public.mirror_documents() -> 'list') = 1;
  r := r || format('5 coordinator with "see and change": adds, deletes only their own, never details without the file: %s', ok);

  -- 6. another person sees nothing; the download lists the details; a day-old upload that never arrived is cleared
  perform set_config('request.jwt.claims', pb, true);
  ok := true;
  begin perform public.mirror_documents(a); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_document_open(d1); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_my_export_documents();
  ok := ok and jsonb_array_length(j) = 1 and j -> 0 ->> 'original_kept' = 'In the blue folder';
  k := public.mirror_document_begin(null, 'other', null, 'never.pdf', 'application/pdf', 10, null, null);
  execute 'reset role';
  update mirror.documents set created_at = now() - interval '2 days' where id = (k ->> 'id')::uuid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_document_begin(null, 'other', null, 'again.pdf', 'application/pdf', 10, null, null);
  execute 'reset role';
  ok := ok and not exists (select 1 from mirror.documents where id = (k ->> 'id')::uuid);
  select count(*) into n from mirror.audit_logs where individual_id = a and table_name = 'documents';
  r := r || format('6 another person refused; download has the details; unfinished uploads cleared; %s audit rows: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
