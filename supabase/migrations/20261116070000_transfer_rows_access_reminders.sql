-- Property transfer cases, part 3:
--  (a) heirs, creditors and documents move out of one big JSON value into their own tables, one row each, with a version per row,
--      so two people editing different people or documents no longer overwrite each other;
--  (b) every case has a list of staff who may open it (admins can open any), enforced in every function and in the file storage policies;
--  (c) a daily job emails the staff on a case about deadlines coming up or overdue (email only, through the existing outbox).

-- ---------------------------------------------------------------------------------------------------------------------------
-- (a) row tables
-- ---------------------------------------------------------------------------------------------------------------------------
create table if not exists property_transfer_heirs (
  id text primary key default gen_random_uuid()::text,
  case_id uuid not null references property_transfer_cases(id) on delete cascade,
  position int not null default 0,
  name text not null,
  relationship text,
  living text check (living in ('living', 'deceased', 'unknown')),
  address text, phone text, email text,
  notice text check (notice in ('none', 'mailed', 'waiver', 'appeared', 'published')),
  notice_on date, tracking text,
  receives boolean not null default false,
  share text,
  extra jsonb not null default '{}'::jsonb,        -- former names, adult/survived/agrees/cansign answers, receipt paths, notes
  version int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by text
);
create index if not exists property_transfer_heirs_case on property_transfer_heirs (case_id, position, created_at);

create table if not exists property_transfer_creditors (
  id text primary key default gen_random_uuid()::text,
  case_id uuid not null references property_transfer_cases(id) on delete cascade,
  position int not null default 0,
  name text not null,
  address text, amount text,
  claim text not null default 'potential' check (claim in ('potential', 'filed', 'accepted', 'disputed')),
  notice text not null default 'none' check (notice in ('none', 'mailed')),
  tracking text, mailed_on date,
  extra jsonb not null default '{}'::jsonb,
  version int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by text
);
create index if not exists property_transfer_creditors_case on property_transfer_creditors (case_id, position, created_at);

create table if not exists property_transfer_documents (
  id text primary key default gen_random_uuid()::text,
  case_id uuid not null references property_transfer_cases(id) on delete cascade,
  position int not null default 0,
  folder text not null check (folder in ('A', 'B', 'C')),
  name text not null,
  form text,
  status text not null default 'todo' check (status in ('todo', 'ordered', 'working', 'ready', 'signed', 'filed')),
  sig boolean,
  ref text, expected date, where_kept text,
  path text, scan_on date,
  recheck boolean not null default false,
  custom boolean not null default false,
  extra jsonb not null default '{}'::jsonb,        -- earlier scan versions and anything else
  version int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by text
);
create index if not exists property_transfer_documents_case on property_transfer_documents (case_id, position, created_at);

alter table property_transfer_heirs enable row level security;
alter table property_transfer_creditors enable row level security;
alter table property_transfer_documents enable row level security;
grant select, insert, update, delete on property_transfer_heirs, property_transfer_creditors, property_transfer_documents to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------
-- (b) who may open a case
-- ---------------------------------------------------------------------------------------------------------------------------
create table if not exists property_transfer_access (
  case_id uuid not null references property_transfer_cases(id) on delete cascade,
  email text not null,
  granted_by text,
  granted_at timestamptz not null default now(),
  primary key (case_id, email)
);
alter table property_transfer_access enable row level security;
grant select, insert, update, delete on property_transfer_access to service_role;

create or replace function transfer_can_access(p_case uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select portal_is_admin()
      or exists (select 1 from property_transfer_access a where a.case_id = p_case and lower(a.email) = lower(auth.email()));
$$;
revoke all on function transfer_can_access(uuid) from public, anon;
grant execute on function transfer_can_access(uuid) to authenticated;

-- Same check for a file path whose first folder is the case id (storage policies).
create or replace function transfer_can_access_folder(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  begin v := ((storage.foldername(p_name))[1])::uuid; exception when others then return false; end;
  return transfer_can_access(v);
end $$;
revoke all on function transfer_can_access_folder(text) from public, anon;
grant execute on function transfer_can_access_folder(text) to authenticated;

drop policy if exists "transfer-docs staff insert" on storage.objects;
create policy "transfer-docs staff insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'transfer-docs' and staff_session_staff() and transfer_can_access_folder(name));
drop policy if exists "transfer-docs staff read" on storage.objects;
create policy "transfer-docs staff read" on storage.objects for select to authenticated
  using (bucket_id = 'transfer-docs' and staff_session_staff() and transfer_can_access_folder(name));
drop policy if exists "transfer-docs staff delete" on storage.objects;
create policy "transfer-docs staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'transfer-docs' and staff_session_staff() and transfer_can_access_folder(name));

-- Every guarded function starts here.
create or replace function transfer_require(p_case uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not transfer_can_access(p_case) then raise exception 'You do not have access to this case' using errcode = '42501'; end if;
end $$;
revoke all on function transfer_require(uuid) from public, anon;
grant execute on function transfer_require(uuid) to authenticated;

create or replace function transfer_access_list(p_case uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform transfer_require(p_case);
  return coalesce((select jsonb_agg(jsonb_build_object('email', a.email, 'granted_by', a.granted_by, 'granted_at', a.granted_at) order by a.granted_at) from property_transfer_access a where a.case_id = p_case), '[]'::jsonb);
end $$;
revoke all on function transfer_access_list(uuid) from public, anon;
grant execute on function transfer_access_list(uuid) to authenticated;

create or replace function transfer_access_grant(p_case uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := lower(trim(coalesce(p_email, '')));
begin
  perform transfer_require(p_case);
  if not exists (select 1 from condo_staff where lower(email) = v) then raise exception 'That person is not on the staff list'; end if;
  insert into property_transfer_access (case_id, email, granted_by) values (p_case, v, auth.jwt()->>'email') on conflict do nothing;
  insert into property_transfer_audit (case_id, actor, action, changed) values (p_case, auth.jwt()->>'email', 'access granted', array[v]);
end $$;
revoke all on function transfer_access_grant(uuid, text) from public, anon;
grant execute on function transfer_access_grant(uuid, text) to authenticated;

create or replace function transfer_access_revoke(p_case uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := lower(trim(coalesce(p_email, '')));
begin
  perform transfer_require(p_case);
  if (select count(*) from property_transfer_access where case_id = p_case) <= 1 and not portal_is_admin() then raise exception 'A case must keep at least one person with access'; end if;
  delete from property_transfer_access where case_id = p_case and lower(email) = v;
  insert into property_transfer_audit (case_id, actor, action, changed) values (p_case, auth.jwt()->>'email', 'access revoked', array[v]);
end $$;
revoke all on function transfer_access_revoke(uuid, text) from public, anon;
grant execute on function transfer_access_revoke(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------
-- row JSON in the same flat shape the page already uses
-- ---------------------------------------------------------------------------------------------------------------------------
create or replace function transfer_heir_json(r property_transfer_heirs) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('id', r.id, 'name', r.name, 'relationship', r.relationship, 'living', r.living, 'address', r.address, 'phone', r.phone, 'email', r.email,
    'notice', r.notice, 'notice_on', r.notice_on, 'tracking', r.tracking, 'receives', r.receives, 'share', r.share, 'version', r.version)) || r.extra;
$$;
create or replace function transfer_creditor_json(r property_transfer_creditors) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('id', r.id, 'name', r.name, 'address', r.address, 'amount', r.amount, 'claim', r.claim, 'notice', r.notice, 'tracking', r.tracking, 'mailed_on', r.mailed_on, 'version', r.version)) || r.extra;
$$;
create or replace function transfer_doc_json(r property_transfer_documents) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('id', r.id, 'folder', r.folder, 'name', r.name, 'form', r.form, 'status', r.status, 'sig', r.sig, 'ref', r.ref, 'expected', r.expected, 'where', r.where_kept,
    'path', r.path, 'on', r.scan_on, 'recheck', r.recheck, 'custom', r.custom, 'version', r.version)) || r.extra;
$$;

-- one row, any of the three kinds. The page sends the whole row; a stale version is refused.
create or replace function transfer_row_save_one(p_kind text, p_case uuid, p jsonb, p_position int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id', '');
  v_exists boolean; v_ver int; v_pos int; v_who text := auth.jwt()->>'email';
  h property_transfer_heirs; c property_transfer_creditors; d property_transfer_documents;
  v_extra jsonb; out jsonb;
begin
  if p_kind not in ('heirs', 'creditors', 'docs') then raise exception 'Unknown kind'; end if;
  if not exists (select 1 from property_transfer_cases where id = p_case) then raise exception 'Case not found'; end if;
  if v_id is null then v_id := gen_random_uuid()::text; end if;

  if p_kind = 'heirs' then
    select true, version into v_exists, v_ver from property_transfer_heirs where id = v_id and case_id = p_case;
    if coalesce(v_exists, false) and p ? 'version' and (p->>'version')::int is distinct from v_ver then raise exception 'This person was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    v_extra := p - array['id','name','relationship','living','address','phone','email','notice','notice_on','tracking','receives','share','version','case_id','position'];
    if coalesce(trim(p->>'name'), '') = '' then raise exception 'A name is required'; end if;
    if coalesce(v_exists, false) then
      update property_transfer_heirs set name = p->>'name', relationship = p->>'relationship', living = nullif(p->>'living',''), address = p->>'address', phone = p->>'phone', email = p->>'email',
        notice = nullif(p->>'notice',''), notice_on = nullif(p->>'notice_on','')::date, tracking = p->>'tracking', receives = coalesce((p->>'receives')::boolean, false), share = p->>'share',
        extra = v_extra, version = version + 1, updated_at = now(), updated_by = v_who where id = v_id and case_id = p_case returning * into h;
    else
      select coalesce(p_position, coalesce(max(position), -1) + 1) into v_pos from property_transfer_heirs where case_id = p_case;
      insert into property_transfer_heirs (id, case_id, position, name, relationship, living, address, phone, email, notice, notice_on, tracking, receives, share, extra, updated_by)
        values (v_id, p_case, v_pos, p->>'name', p->>'relationship', nullif(p->>'living',''), p->>'address', p->>'phone', p->>'email', nullif(p->>'notice',''), nullif(p->>'notice_on','')::date, p->>'tracking',
                coalesce((p->>'receives')::boolean, false), p->>'share', v_extra, v_who) returning * into h;
    end if;
    out := transfer_heir_json(h);
  elsif p_kind = 'creditors' then
    select true, version into v_exists, v_ver from property_transfer_creditors where id = v_id and case_id = p_case;
    if coalesce(v_exists, false) and p ? 'version' and (p->>'version')::int is distinct from v_ver then raise exception 'This creditor was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    v_extra := p - array['id','name','address','amount','claim','notice','tracking','mailed_on','version','case_id','position'];
    if coalesce(trim(p->>'name'), '') = '' then raise exception 'A name is required'; end if;
    if coalesce(v_exists, false) then
      update property_transfer_creditors set name = p->>'name', address = p->>'address', amount = p->>'amount', claim = coalesce(nullif(p->>'claim',''), 'potential'), notice = coalesce(nullif(p->>'notice',''), 'none'),
        tracking = p->>'tracking', mailed_on = nullif(p->>'mailed_on','')::date, extra = v_extra, version = version + 1, updated_at = now(), updated_by = v_who where id = v_id and case_id = p_case returning * into c;
    else
      select coalesce(p_position, coalesce(max(position), -1) + 1) into v_pos from property_transfer_creditors where case_id = p_case;
      insert into property_transfer_creditors (id, case_id, position, name, address, amount, claim, notice, tracking, mailed_on, extra, updated_by)
        values (v_id, p_case, v_pos, p->>'name', p->>'address', p->>'amount', coalesce(nullif(p->>'claim',''), 'potential'), coalesce(nullif(p->>'notice',''), 'none'), p->>'tracking', nullif(p->>'mailed_on','')::date, v_extra, v_who) returning * into c;
    end if;
    out := transfer_creditor_json(c);
  else
    select true, version into v_exists, v_ver from property_transfer_documents where id = v_id and case_id = p_case;
    if coalesce(v_exists, false) and p ? 'version' and (p->>'version')::int is distinct from v_ver then raise exception 'This document was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    v_extra := p - array['id','folder','name','form','status','sig','ref','expected','where','path','on','recheck','custom','version','case_id','position'];
    if coalesce(trim(p->>'name'), '') = '' then raise exception 'A name is required'; end if;
    if coalesce(v_exists, false) then
      update property_transfer_documents set folder = p->>'folder', name = p->>'name', form = p->>'form', status = coalesce(nullif(p->>'status',''), 'todo'), sig = (p->>'sig')::boolean, ref = p->>'ref',
        expected = nullif(p->>'expected','')::date, where_kept = p->>'where', path = p->>'path', scan_on = nullif(p->>'on','')::date, recheck = coalesce((p->>'recheck')::boolean, false),
        custom = coalesce((p->>'custom')::boolean, false), extra = v_extra, version = version + 1, updated_at = now(), updated_by = v_who where id = v_id and case_id = p_case returning * into d;
    else
      select coalesce(p_position, coalesce(max(position), -1) + 1) into v_pos from property_transfer_documents where case_id = p_case;
      insert into property_transfer_documents (id, case_id, position, folder, name, form, status, sig, ref, expected, where_kept, path, scan_on, recheck, custom, extra, updated_by)
        values (v_id, p_case, v_pos, p->>'folder', p->>'name', p->>'form', coalesce(nullif(p->>'status',''), 'todo'), (p->>'sig')::boolean, p->>'ref', nullif(p->>'expected','')::date, p->>'where', p->>'path',
                nullif(p->>'on','')::date, coalesce((p->>'recheck')::boolean, false), coalesce((p->>'custom')::boolean, false), v_extra, v_who) returning * into d;
    end if;
    out := transfer_doc_json(d);
  end if;
  update property_transfer_cases set updated_at = now() where id = p_case;
  insert into property_transfer_audit (case_id, actor, action, changed) values (p_case, v_who, case when coalesce(v_exists, false) then 'update' else 'create' end, array[p_kind || ':' || v_id]);
  return out;
end $$;
revoke all on function transfer_row_save_one(text, uuid, jsonb, int) from public, anon;

create or replace function transfer_row_save(p_kind text, p_case uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform transfer_require(p_case);
  return transfer_row_save_one(p_kind, p_case, p);
end $$;
revoke all on function transfer_row_save(text, uuid, jsonb) from public, anon;
grant execute on function transfer_row_save(text, uuid, jsonb) to authenticated;

-- Many rows at once (for example the standard documents); keeps the given order. All succeed or none.
create or replace function transfer_rows_save(p_kind text, p_case uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e jsonb; i int := 0; res jsonb := '[]'::jsonb; base int;
begin
  perform transfer_require(p_case);
  if jsonb_typeof(p) <> 'array' then raise exception 'A list is required'; end if;
  execute format('select coalesce(max(position), -1) + 1 from %I where case_id = $1', case p_kind when 'heirs' then 'property_transfer_heirs' when 'creditors' then 'property_transfer_creditors' when 'docs' then 'property_transfer_documents' else null end) into base using p_case;
  for e in select * from jsonb_array_elements(p) loop
    res := res || jsonb_build_array(transfer_row_save_one(p_kind, p_case, e, base + i)); i := i + 1;
  end loop;
  return res;
end $$;
revoke all on function transfer_rows_save(text, uuid, jsonb) from public, anon;
grant execute on function transfer_rows_save(text, uuid, jsonb) to authenticated;

create or replace function transfer_row_delete(p_kind text, p_case uuid, p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform transfer_require(p_case);
  if p_kind = 'heirs' then delete from property_transfer_heirs where id = p_id and case_id = p_case;
  elsif p_kind = 'creditors' then delete from property_transfer_creditors where id = p_id and case_id = p_case;
  elsif p_kind = 'docs' then delete from property_transfer_documents where id = p_id and case_id = p_case;
  else raise exception 'Unknown kind'; end if;
  update property_transfer_cases set updated_at = now() where id = p_case;
  insert into property_transfer_audit (case_id, actor, action, changed) values (p_case, auth.jwt()->>'email', 'delete', array[p_kind || ':' || p_id]);
end $$;
revoke all on function transfer_row_delete(text, uuid, text) from public, anon;
grant execute on function transfer_row_delete(text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------
-- move the existing data
-- ---------------------------------------------------------------------------------------------------------------------------
do $$
declare c record; e jsonb; i int;
begin
  for c in select id, heirs, meta from property_transfer_cases loop
    i := 0;
    for e in select * from jsonb_array_elements(coalesce(c.heirs, '[]'::jsonb)) loop
      insert into property_transfer_heirs (id, case_id, position, name, relationship, living, address, phone, email, notice, notice_on, tracking, receives, share, extra)
        values (coalesce(nullif(e->>'id',''), gen_random_uuid()::text), c.id, i, coalesce(nullif(e->>'name',''), '(no name)'), e->>'relationship', nullif(e->>'living',''), e->>'address', e->>'phone', e->>'email',
                nullif(e->>'notice',''), nullif(e->>'notice_on','')::date, e->>'tracking', coalesce((e->>'receives')::boolean, false), e->>'share',
                e - array['id','name','relationship','living','address','phone','email','notice','notice_on','tracking','receives','share','version'])
        on conflict (id) do nothing;
      i := i + 1;
    end loop;
    i := 0;
    for e in select * from jsonb_array_elements(coalesce(c.meta->'creditors', '[]'::jsonb)) loop
      insert into property_transfer_creditors (id, case_id, position, name, address, amount, claim, notice, tracking, mailed_on, extra)
        values (coalesce(nullif(e->>'id',''), gen_random_uuid()::text), c.id, i, coalesce(nullif(e->>'name',''), '(no name)'), e->>'address', e->>'amount', coalesce(nullif(e->>'claim',''), 'potential'),
                coalesce(nullif(e->>'notice',''), 'none'), e->>'tracking', nullif(e->>'mailed_on','')::date, e - array['id','name','address','amount','claim','notice','tracking','mailed_on','version'])
        on conflict (id) do nothing;
      i := i + 1;
    end loop;
    i := 0;
    for e in select * from jsonb_array_elements(coalesce(c.meta->'docs', '[]'::jsonb)) loop
      insert into property_transfer_documents (id, case_id, position, folder, name, form, status, sig, ref, expected, where_kept, path, scan_on, recheck, custom, extra)
        values (coalesce(nullif(e->>'id',''), gen_random_uuid()::text), c.id, i, coalesce(nullif(e->>'folder',''), 'C'), coalesce(nullif(e->>'name',''), '(document)'), e->>'form', coalesce(nullif(e->>'status',''), 'todo'),
                (e->>'sig')::boolean, e->>'ref', nullif(e->>'expected','')::date, e->>'where', e->>'path', nullif(e->>'on','')::date, coalesce((e->>'recheck')::boolean, false), coalesce((e->>'custom')::boolean, false),
                e - array['id','folder','name','form','status','sig','ref','expected','where','path','on','recheck','custom','version'])
        on conflict (id) do nothing;
      i := i + 1;
    end loop;
    update property_transfer_cases set heirs = '[]'::jsonb, meta = meta - 'creditors' - 'docs' where id = c.id;
    -- nobody loses access they had: every current staff member keeps access to the cases that already exist
    insert into property_transfer_access (case_id, email, granted_by) select c.id, lower(s.email), 'migration' from condo_staff s on conflict do nothing;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------
-- case functions: access checks, rows folded back into the case, no more writing the three lists as JSON
-- ---------------------------------------------------------------------------------------------------------------------------
create or replace function transfer_staff_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(
      (to_jsonb(c)
        || jsonb_build_object(
          'heirs', coalesce((select jsonb_agg(transfer_heir_json(h) order by h.position, h.created_at) from property_transfer_heirs h where h.case_id = c.id), '[]'::jsonb),
          'creditors', coalesce((select jsonb_agg(transfer_creditor_json(r) order by r.position, r.created_at) from property_transfer_creditors r where r.case_id = c.id), '[]'::jsonb),
          'docs', coalesce((select jsonb_agg(transfer_doc_json(d) order by d.position, d.created_at) from property_transfer_documents d where d.case_id = c.id), '[]'::jsonb))
      ) order by c.updated_at desc)
    from property_transfer_cases c where transfer_can_access(c.id)), '[]'::jsonb);
end $$;
revoke all on function transfer_staff_list() from public, anon;
grant execute on function transfer_staff_list() to authenticated;

create or replace function transfer_staff_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_new boolean := false;
  v_changed text[];
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if v_id is not null then perform transfer_require(v_id); end if;
  if p ? 'heirs' then raise exception 'Heirs are saved one at a time (transfer_row_save)'; end if;
  if p ? 'meta' and (p->'meta' ? 'creditors' or p->'meta' ? 'docs') then raise exception 'Creditors and documents are saved one row at a time (transfer_row_save)'; end if;
  if p ? 'todi_recorded' and p->>'todi_recorded' not in ('yes','no','unknown') then raise exception 'todi_recorded must be yes, no or unknown'; end if;
  if p ? 'death_cert' then
    if jsonb_typeof(p->'death_cert') <> 'object' then raise exception 'death_cert must be an object'; end if;
    if exists (select 1 from jsonb_object_keys(p->'death_cert') k where k <> all (array['residence_address','legal_name','date_of_birth','place_of_death','county_of_residence','marital_status','surviving_spouse','certificate_number','issue_date','informant','copies','ssn_last4','file_path','uploaded_on'])) then
      raise exception 'Unexpected field in the death certificate details';
    end if;
    if coalesce(p->'death_cert'->>'ssn_last4', '') !~ '^(\d{4})?$' then raise exception 'Enter only the last four digits of the Social Security number'; end if;
  end if;
  if p ? 'decedent_aka' and jsonb_typeof(p->'decedent_aka') <> 'array' then raise exception 'decedent_aka must be a list'; end if;
  if p ? 'record_search' and jsonb_typeof(p->'record_search') <> 'object' then raise exception 'record_search must be an object'; end if;
  if v_id is null then
    insert into property_transfer_cases (title, property_address, pins, property_county, legal_description, decedent_name, case_type, created_by)
      values (coalesce(p->>'title', ''), p->>'property_address', p->>'pins', p->>'property_county', p->>'legal_description', p->>'decedent_name',
              coalesce(nullif(p->>'case_type', ''), 'death_transfer'), auth.jwt()->>'email')
      returning id into v_id;
    insert into property_transfer_access (case_id, email, granted_by) values (v_id, lower(auth.email()), 'creator') on conflict do nothing;
    v_new := true;
  elsif p ? 'expected_version' then
    if not exists (select 1 from property_transfer_cases c where c.id = v_id and c.version = (p->>'expected_version')::int) then
      raise exception 'This case was changed somewhere else since you opened it. Reload the page and try again.' using errcode = '40001';
    end if;
  end if;
  update property_transfer_cases c set
    title = case when p ? 'title' then coalesce(p->>'title', '') else c.title end,
    property_address = case when p ? 'property_address' then p->>'property_address' else c.property_address end,
    pins = case when p ? 'pins' then p->>'pins' else c.pins end,
    property_county = case when p ? 'property_county' then p->>'property_county' else c.property_county end,
    legal_description = case when p ? 'legal_description' then p->>'legal_description' else c.legal_description end,
    decedent_name = case when p ? 'decedent_name' then p->>'decedent_name' else c.decedent_name end,
    decedent_aka = case when p ? 'decedent_aka' then coalesce(p->'decedent_aka', '[]'::jsonb) else c.decedent_aka end,
    owner_of_record_doc = case when p ? 'owner_of_record_doc' then p->>'owner_of_record_doc' else c.owner_of_record_doc end,
    record_search = case when p ? 'record_search' then coalesce(p->'record_search', '{}'::jsonb) else c.record_search end,
    date_of_death = case when p ? 'date_of_death' then nullif(p->>'date_of_death', '')::date else c.date_of_death end,
    death_cert = case when p ? 'death_cert' then coalesce(p->'death_cert', '{}'::jsonb) else c.death_cert end,
    meta = case when p ? 'meta' then coalesce(p->'meta', '{}'::jsonb) else c.meta end,
    heirs_check = case when p ? 'heirs_check' then coalesce(p->'heirs_check', '{}'::jsonb) else c.heirs_check end,
    todi_recorded = case when p ? 'todi_recorded' then p->>'todi_recorded' else c.todi_recorded end,
    decisions = case when p ? 'decisions' then coalesce(p->'decisions', '{}'::jsonb) else c.decisions end,
    heir_candidates = case when p ? 'heir_candidates' then coalesce(p->'heir_candidates', '[]'::jsonb) else c.heir_candidates end,
    heir_name = case when p ? 'heir_name' then nullif(trim(coalesce(p->>'heir_name', '')), '') else c.heir_name end,
    heir_name_how = case when p ? 'heir_name_how' then nullif(p->>'heir_name_how', '') else c.heir_name_how end,
    representative = case when p ? 'representative' then p->>'representative' else c.representative end,
    deed_id = case when p ? 'deed_id' then nullif(p->>'deed_id', '')::uuid else c.deed_id end,
    steps = case when p ? 'steps' then coalesce(p->'steps', '{}'::jsonb) else c.steps end,
    notes = case when p ? 'notes' then p->>'notes' else c.notes end,
    version = c.version + 1,
    updated_at = now()
  where c.id = v_id;
  if not found then raise exception 'Case not found'; end if;
  select coalesce(array_agg(k order by k), '{}') into v_changed from jsonb_object_keys(p) k where k not in ('id', 'expected_version');
  insert into property_transfer_audit (case_id, actor, action, changed) values (v_id, auth.jwt()->>'email', case when v_new then 'create' else 'update' end, v_changed);
  return v_id;
end $$;
revoke all on function transfer_staff_save(jsonb) from public, anon;
grant execute on function transfer_staff_save(jsonb) to authenticated;

create or replace function transfer_staff_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform transfer_require(p_id);
  insert into property_transfer_audit (case_id, actor, action, changed) values (p_id, auth.jwt()->>'email', 'delete', '{}');
  delete from property_transfer_cases where id = p_id;
end $$;
revoke all on function transfer_staff_delete(uuid) from public, anon;
grant execute on function transfer_staff_delete(uuid) to authenticated;

create or replace function transfer_staff_audit(p_case uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform transfer_require(p_case);
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'actor', a.actor, 'action', a.action, 'changed', a.changed) order by a.at desc)
                     from (select * from property_transfer_audit where case_id = p_case order by at desc limit 100) a), '[]'::jsonb);
end $$;
revoke all on function transfer_staff_audit(uuid) from public, anon;
grant execute on function transfer_staff_audit(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------
-- (c) deadline reminders by email, once per deadline per lead time
-- ---------------------------------------------------------------------------------------------------------------------------
create table if not exists property_transfer_reminders_sent (
  case_id uuid not null references property_transfer_cases(id) on delete cascade,
  key text not null,
  sent_on date not null default current_date,
  primary key (case_id, key)
);
alter table property_transfer_reminders_sent enable row level security;
grant select, insert, delete on property_transfer_reminders_sent to service_role;

-- The dates a case is waiting on: a target date set on a step, and the estimates worked out from the court dates entered on the case.
create or replace function transfer_case_deadlines(p_case uuid) returns table (item_key text, label text, due date)
language plpgsql stable security definer set search_path = public as $$
declare c property_transfer_cases; d jsonb; s record; cr record; pub date; will boolean; admin boolean;
begin
  select * into c from property_transfer_cases where id = p_case;
  if not found then return; end if;
  d := coalesce(c.meta->'dates', '{}'::jsonb);
  will := coalesce(c.decisions->>'will', '') = 'yes';
  admin := coalesce(c.decisions->>'route', '') in ('admin_ind', 'admin_sup');
  for s in select k as id, v from jsonb_each(c.steps) as t(k, v) where coalesce(v->>'due', '') <> '' and coalesce(v->>'status', 'todo') not in ('done', 'na') loop
    item_key := 'step:' || s.id; label := coalesce(nullif(s.v->>'title', ''), 'A step with a target date'); due := (s.v->>'due')::date; return next;
  end loop;
  if admin then
    if coalesce(d->>'hearing', '') <> '' and not will then item_key := 'mail30'; label := 'Mail the petition by certified mail to the heirs who rank equal or higher to serve (at least 30 days before the hearing)'; due := (d->>'hearing')::date - 30; return next; end if;
    if coalesce(d->>'order', '') <> '' then item_key := 'order14'; label := 'Mail the petition and the court order by certified mail to the other heirs, and start the newspaper notice if any address is unknown (within 14 days after the order)'; due := (d->>'order')::date + 14; return next; end if;
    if coalesce(d->>'letters', '') <> '' then item_key := 'inv60'; label := 'Prepare and deliver (or file) the inventory of the estate (within 60 days after the letters)'; due := (d->>'letters')::date + 60; return next; end if;
    if coalesce(d->>'pub', '') <> '' then
      pub := (d->>'pub')::date;
      item_key := 'claims'; label := 'Earliest claims deadline to state in the creditor notice (6 months after first publication)'; due := (pub + interval '6 months')::date; return next;
      for cr in select id, name, mailed_on from property_transfer_creditors where case_id = p_case and mailed_on is not null loop
        item_key := 'cred:' || cr.id; label := 'Claims deadline to state for creditor ' || cr.name; due := greatest((pub + interval '6 months')::date, (cr.mailed_on + interval '3 months')::date); return next;
      end loop;
    end if;
  end if;
end $$;
revoke all on function transfer_case_deadlines(uuid) from public, anon, authenticated;

-- Runs from pg_cron. Lead times: 7, 3 and 1 days before, the day itself, and 1 and 7 days overdue. One email per case per run to everyone with access.
create or replace function transfer_deadline_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare cs record; it record; today date := (now() at time zone 'America/Chicago')::date; days int; bucket text; html text; n int := 0; r record; subj text;
begin
  for cs in select id, property_address from property_transfer_cases loop
    html := ''; subj := null;
    for it in select * from transfer_case_deadlines(cs.id) loop
      days := it.due - today;
      if days in (7, 3, 1, 0, -1, -7) then
        bucket := it.item_key || ':' || it.due::text || ':' || days::text;
        insert into property_transfer_reminders_sent (case_id, key) values (cs.id, bucket) on conflict do nothing;
        if found then
          html := html || '<li><b>' || to_char(it.due, 'FMMM/FMDD/YYYY') || '</b>: ' || replace(replace(it.label, '&', '&amp;'), '<', '&lt;') || ' <i>(' ||
                  case when days > 0 then 'in ' || days || ' day' || case when days = 1 then '' else 's' end when days = 0 then 'today' else (-days) || ' day' || case when days = -1 then '' else 's' end || ' overdue' end || ')</i></li>';
          n := n + 1;
        end if;
      end if;
    end loop;
    if html <> '' then
      subj := 'Property transfer case: deadline reminder';
      for r in select email from property_transfer_access where case_id = cs.id loop
        insert into email_outbox (to_email, subject, html, kind) values (r.email, subj,
          '<p>These dates on a property transfer case need attention' || case when coalesce(cs.property_address, '') <> '' then ' (' || replace(replace(cs.property_address, '&', '&amp;'), '<', '&lt;') || ')' else '' end || ':</p><ul>' || html ||
          '</ul><p>Open the case: <a href="https://2ndchinc.org/staff/deeds/transfer/">https://2ndchinc.org/staff/deeds/transfer/</a></p><p style="color:#666;font-size:12px">These dates are estimates worked out from the Probate Act and the dates entered on the case. They are not legal advice or court-set deadlines; confirm them with counsel or the court.</p>',
          'transfer_reminder');
      end loop;
    end if;
  end loop;
  return n;
end $$;
revoke all on function transfer_deadline_reminders() from public, anon, authenticated;

select cron.schedule('transfer-deadline-reminders-a', '30 4 * * *', 'select transfer_deadline_reminders()');
select cron.schedule('transfer-deadline-reminders-b', '30 5 * * *', 'select transfer_deadline_reminders()');
