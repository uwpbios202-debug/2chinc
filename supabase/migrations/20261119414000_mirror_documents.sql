-- The Human Mirror T7.4: documents (Phase 7, step 7 of the handoff, the last Phase 7 step).
-- "document_types, documents, private bucket mirror-docs, edge function mirror-files (signed links)."
--
-- How it works (SECURITY_PLAN.md 1.6)
--   * Files live in the PRIVATE bucket mirror-docs with NO storage policy for authenticated or anon at all: no browser can read, list,
--     upload or delete there by itself. Only the edge function mirror-files (service role) hands out signed links, and only after the
--     database gate below says yes for THIS signed-in person.
--   * Upload: the page asks mirror-files; it calls mirror_document_begin AS THE SIGNED-IN PERSON (gate: edit on the type's topic), which
--     records the details and the file's place (<person id>/<document id>, no name in the path); mirror-files returns a one-time signed
--     upload link for exactly that place. A document is "there" only once its file exists; details without a file are never shown and
--     are cleared after a day.
--   * Open: mirror-files calls mirror_document_open as the person (gate: view; a coordinator's look is in the person's "who looked"),
--     then returns a link that works for 5 minutes.
--   * Delete: the person, or the coordinator who added it (with "see and change" for Documents). mirror-files checks
--     (mirror_document_delete_check), removes the file, then mirror_document_delete removes the details, which it refuses while the
--     file still exists (so no file is ever left without its details).
--   * Topic: each type has its privacy topic (all "documents" today). Coordinators see documents only with the person's consent for
--     that topic (role_permissions: needs_consent); no counts or hints otherwise (D-29).
--   * Data minimization (SECURITY_PLAN 1.10): no document numbers are asked for or stored; only the type, a short name, an optional
--     expiry date and an optional note on where the paper original is kept.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only, no TRUNCATE; authenticated and anon none.

-- ---------------------------------------------------------------- tables
create table mirror.document_types (
  key text primary key check (key ~ '^[a-z_]+$'),
  label text not null,
  category text not null default 'documents' check (category in ('documents', 'health', 'legal', 'immigration', 'financial')),
  has_expiry boolean not null default false,
  sort int not null default 100
);

insert into mirror.document_types (key, label, category, has_expiry, sort) values
  ('state_id', 'State ID or driver''s license', 'documents', true, 10),
  ('birth_certificate', 'Birth certificate', 'documents', false, 20),
  ('social_security_card', 'Social Security card', 'documents', false, 30),
  ('insurance_card', 'Health insurance card (BadgerCare, Medicare and others)', 'documents', true, 40),
  ('income_proof', 'Proof of income (pay stubs, benefit amount)', 'documents', false, 50),
  ('benefit_letter', 'Benefit letter (SSI, SSDI, FoodShare and others)', 'documents', false, 60),
  ('lease', 'Lease or housing paper', 'documents', true, 70),
  ('other', 'Other document', 'documents', false, 900);

create table mirror.documents (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  type_key text not null references mirror.document_types(key),
  title text check (title is null or length(title) between 1 and 120),
  file_name text not null check (length(file_name) between 1 and 120),
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif')),
  size_bytes bigint not null check (size_bytes between 1 and 10485760),
  storage_path text not null unique,
  expires_on date,
  location_note text check (location_note is null or length(location_note) <= 300),
  uploaded_by text not null,
  uploaded_by_role text not null,
  organization_id uuid references mirror.organizations(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index documents_individual on mirror.documents (individual_id, created_at);

alter table mirror.document_types enable row level security;
alter table mirror.documents enable row level security;
revoke all on mirror.document_types, mirror.documents from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.document_types, mirror.documents to service_role;

-- ---------------------------------------------------------------- the bucket: private, no policies (only signed links)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('mirror-docs', 'mirror-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------- helpers
create or replace function mirror.document_file_exists(p_path text) returns boolean
language sql stable security definer set search_path = mirror, public, storage as $$
  select exists (select 1 from storage.objects o where o.bucket_id = 'mirror-docs' and o.name = p_path);
$$;

create or replace function mirror.document_json(d mirror.documents) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', d.id, 'type', d.type_key, 'type_label', t.label, 'category', t.category, 'title', d.title,
    'file_name', d.file_name, 'mime', d.mime, 'size_bytes', d.size_bytes, 'expires_on', d.expires_on, 'location_note', d.location_note,
    'added_by_role', d.uploaded_by_role, 'added_by_me', d.uploaded_by = lower(auth.email()),
    'added_by_org', (select o.name from mirror.organizations o where o.id = d.organization_id),
    'created_at', d.created_at, 'updated_at', d.updated_at)
  from mirror.document_types t where t.key = d.type_key;
$$;

-- May the caller delete this document? The person always; a member only one they added, with "see and change" for its topic.
create or replace function mirror.document_may_delete(d mirror.documents) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare r jsonb; v_cat text := (select category from mirror.document_types where key = d.type_key);
begin
  r := mirror.require(d.individual_id, v_cat, 'edit', null, 'documents', d.id::text);
  return r ->> 'role' = 'self' or d.uploaded_by = lower(auth.email());
end $$;

-- ---------------------------------------------------------------- what the pages call
-- The documents the caller may see for a person (or their own), the types, and what they may do.
create or replace function public.mirror_documents(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); v_cats text[] := '{}'; c text; r jsonb; v_reason text; v_role text;
begin
  for c in select distinct category from mirror.document_types loop
    r := mirror.allowed(v, c, 'view', null, 'documents', null);
    if (r ->> 'ok')::boolean then v_cats := v_cats || c; v_role := r ->> 'role'; else v_reason := coalesce(v_reason, r ->> 'reason'); end if;
  end loop;
  if cardinality(v_cats) = 0 then raise exception '%', coalesce(v_reason, 'Not allowed.') using errcode = '42501'; end if;
  return jsonb_build_object(
    'role', v_role,
    'types', (select jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'category', t.category, 'has_expiry', t.has_expiry,
                'can_add', mirror.may(v, t.category, 'edit')) order by t.sort, t.label) from mirror.document_types t where t.category = any (v_cats)),
    'list', coalesce((select jsonb_agg(mirror.document_json(d) || jsonb_build_object('can_delete',
                (v_role = 'self' or (d.uploaded_by = lower(auth.email()) and mirror.may(v, t.category, 'edit'))),
                'can_edit', mirror.may(v, t.category, 'edit')) order by t.sort, d.created_at desc)
              from mirror.documents d join mirror.document_types t on t.key = d.type_key
              where d.individual_id = v and t.category = any (v_cats) and mirror.document_file_exists(d.storage_path)), '[]'::jsonb));
end $$;

-- Step 1 of an upload (called by mirror-files as the signed-in person): checks, records the details, returns the file's place.
create or replace function public.mirror_document_begin(p_individual uuid, p_type text, p_title text, p_file_name text, p_mime text,
  p_size bigint, p_expires_on date, p_location_note text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); t mirror.document_types; r jsonb; v_id uuid := gen_random_uuid(); v_name text;
begin
  select * into t from mirror.document_types where key = p_type;
  if t.key is null then raise exception 'Choose what kind of document it is.' using errcode = '22023'; end if;
  r := mirror.require(v, t.category, 'edit', null, 'documents', v_id::text);
  if p_mime is null or p_mime not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif') then
    raise exception 'That kind of file can''t be kept here. Use a photo (JPG, PNG, HEIC) or a PDF.' using errcode = '22023';
  end if;
  if p_size is null or p_size < 1 then raise exception 'That file is empty.' using errcode = '22023'; end if;
  if p_size > 10485760 then raise exception 'That file is bigger than 10 MB. Take the photo again, or save a smaller PDF.' using errcode = '22023'; end if;
  if length(coalesce(p_title, '')) > 120 then raise exception 'The name is too long (120 characters at most).' using errcode = '22023'; end if;
  if length(coalesce(p_location_note, '')) > 300 then raise exception 'The note is too long (300 characters at most).' using errcode = '22023'; end if;
  if p_expires_on is not null and p_expires_on < date '1990-01-01' then raise exception 'That expiry date does not look right.' using errcode = '22023'; end if;
  -- details whose file never arrived are cleared after a day (they were never shown)
  delete from mirror.documents d where d.individual_id = v and d.created_at < now() - interval '1 day' and not mirror.document_file_exists(d.storage_path);
  if (select count(*) from mirror.documents where individual_id = v) >= 200 then raise exception 'That is 200 documents. Delete some you no longer need first.'; end if;
  if (select count(*) from mirror.documents where uploaded_by = lower(auth.email()) and created_at > now() - interval '1 day') >= 50 then
    raise exception 'That is 50 uploads in a day. Please try again tomorrow.';
  end if;
  v_name := left(nullif(regexp_replace(btrim(coalesce(p_file_name, '')), '[\\/[:cntrl:]]', '', 'g'), ''), 120);
  insert into mirror.documents (id, individual_id, type_key, title, file_name, mime, size_bytes, storage_path, expires_on, location_note,
                                uploaded_by, uploaded_by_role, organization_id)
  values (v_id, v, t.key, nullif(btrim(coalesce(p_title, '')), ''), coalesce(v_name, 'document'), p_mime, p_size, v::text || '/' || v_id::text,
          case when t.has_expiry then p_expires_on end, nullif(btrim(coalesce(p_location_note, '')), ''),
          lower(auth.email()), r ->> 'role', nullif(r ->> 'organization_id', '')::uuid);
  return jsonb_build_object('id', v_id, 'path', v::text || '/' || v_id::text);
end $$;

-- Change a document's details (not the file).
create or replace function public.mirror_document_update(p_id uuid, p_type text, p_title text, p_expires_on date, p_location_note text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare d mirror.documents; t mirror.document_types;
begin
  select * into d from mirror.documents where id = p_id;
  if d.id is null then raise exception 'Not found.' using errcode = '42501'; end if;
  perform mirror.require(d.individual_id, (select category from mirror.document_types where key = d.type_key), 'edit', null, 'documents', d.id::text);
  select * into t from mirror.document_types where key = coalesce(p_type, d.type_key);
  if t.key is null then raise exception 'Choose what kind of document it is.' using errcode = '22023'; end if;
  if t.key <> d.type_key then perform mirror.require(d.individual_id, t.category, 'edit', null, 'documents', d.id::text); end if;
  if length(coalesce(p_title, '')) > 120 then raise exception 'The name is too long (120 characters at most).' using errcode = '22023'; end if;
  if length(coalesce(p_location_note, '')) > 300 then raise exception 'The note is too long (300 characters at most).' using errcode = '22023'; end if;
  update mirror.documents set type_key = t.key, title = nullif(btrim(coalesce(p_title, '')), ''),
    expires_on = case when t.has_expiry then p_expires_on end, location_note = nullif(btrim(coalesce(p_location_note, '')), ''), updated_at = now()
  where id = p_id returning * into d;
  return mirror.document_json(d);
end $$;

-- Opening a file (called by mirror-files as the signed-in person): the gate logs a coordinator's look; returns the file's place.
create or replace function public.mirror_document_open(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare d mirror.documents;
begin
  select * into d from mirror.documents where id = p_id;
  if d.id is null then raise exception 'Not found.' using errcode = '42501'; end if;
  perform mirror.require(d.individual_id, (select category from mirror.document_types where key = d.type_key), 'view', null, 'documents', d.id::text);
  if not mirror.document_file_exists(d.storage_path) then raise exception 'That file is not there any more.'; end if;
  return jsonb_build_object('path', d.storage_path, 'file_name', d.file_name, 'mime', d.mime);
end $$;

-- Deleting, step 1 (mirror-files, as the person): may they? Returns the file's place so the function can remove it.
create or replace function public.mirror_document_delete_check(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare d mirror.documents;
begin
  select * into d from mirror.documents where id = p_id;
  if d.id is null then raise exception 'Not found.' using errcode = '42501'; end if;
  if not mirror.document_may_delete(d) then raise exception 'Only the person, or whoever added it, can delete it.' using errcode = '42501'; end if;
  return jsonb_build_object('path', d.storage_path);
end $$;

-- Deleting, step 2: removes the details once the file is gone (refused while the file is still there).
create or replace function public.mirror_document_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare d mirror.documents;
begin
  select * into d from mirror.documents where id = p_id;
  if d.id is null then return false; end if;
  if not mirror.document_may_delete(d) then raise exception 'Only the person, or whoever added it, can delete it.' using errcode = '42501'; end if;
  if mirror.document_file_exists(d.storage_path) then raise exception 'Delete the document from its page.' using errcode = '42501'; end if;
  delete from mirror.documents where id = p_id;
  return true;
end $$;

-- Settings: the person's download and printable copy (the details; the files themselves open from the Documents page).
create or replace function public.mirror_my_export_documents() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.require(v, 'documents', 'view', null, 'documents', null);
  return coalesce((select jsonb_agg(jsonb_build_object('type', t.label, 'name', coalesce(d.title, d.file_name), 'file', d.file_name,
      'size_bytes', d.size_bytes, 'expires_on', d.expires_on, 'original_kept', d.location_note, 'added_by', d.uploaded_by_role,
      'added_at', d.created_at) order by t.sort, d.created_at)
    from mirror.documents d join mirror.document_types t on t.key = d.type_key
    where d.individual_id = v and mirror.document_file_exists(d.storage_path)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function mirror.document_file_exists(text), mirror.document_json(mirror.documents), mirror.document_may_delete(mirror.documents)
  from public, anon, authenticated;
grant execute on function mirror.document_file_exists(text), mirror.document_json(mirror.documents), mirror.document_may_delete(mirror.documents)
  to service_role;
revoke all on function public.mirror_documents(uuid), public.mirror_document_begin(uuid, text, text, text, text, bigint, date, text),
  public.mirror_document_update(uuid, text, text, date, text), public.mirror_document_open(uuid), public.mirror_document_delete_check(uuid),
  public.mirror_document_delete(uuid), public.mirror_my_export_documents() from public, anon;
grant execute on function public.mirror_documents(uuid), public.mirror_document_begin(uuid, text, text, text, text, bigint, date, text),
  public.mirror_document_update(uuid, text, text, date, text), public.mirror_document_open(uuid), public.mirror_document_delete_check(uuid),
  public.mirror_document_delete(uuid), public.mirror_my_export_documents() to authenticated, service_role;
