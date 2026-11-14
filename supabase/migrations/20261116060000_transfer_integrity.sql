-- Property transfer cases: integrity and accountability.
--  * version: every save sends the version it read; a stale save is refused instead of silently overwriting a newer one.
--  * saving a case that does not exist is an error (it used to return the id with nothing updated).
--  * the title-search facts (owner_of_record_doc, record_search, decedent_aka) can now be saved through the same function.
--  * death_cert only accepts the known fields (and only four digits of the Social Security number); other JSON is refused.
--  * property_transfer_audit records who changed which fields and when; transfer_staff_audit() lists the history for staff.
--  * the transfer-docs bucket is forced private with its size and type limits even if it already existed.
alter table property_transfer_cases add column if not exists version int not null default 0;

create table if not exists property_transfer_audit (
  id bigint generated always as identity primary key,
  case_id uuid not null,
  actor text,
  action text not null,
  changed text[] not null default '{}',
  at timestamptz not null default now()
);
create index if not exists property_transfer_audit_case on property_transfer_audit (case_id, at desc);
alter table property_transfer_audit enable row level security;
grant select, insert on property_transfer_audit to service_role;
grant usage on sequence property_transfer_audit_id_seq to service_role;

update storage.buckets set public = false, file_size_limit = 15728640,
  allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic']
  where id = 'transfer-docs';

create or replace function transfer_staff_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_new boolean := false;
  v_changed text[];
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p ? 'todi_recorded' and p->>'todi_recorded' not in ('yes','no','unknown') then raise exception 'todi_recorded must be yes, no or unknown'; end if;
  if p ? 'death_cert' then
    if jsonb_typeof(p->'death_cert') <> 'object' then raise exception 'death_cert must be an object'; end if;
    if exists (select 1 from jsonb_object_keys(p->'death_cert') k where k <> all (array['residence_address','legal_name','date_of_birth','place_of_death','county_of_residence','marital_status','surviving_spouse','certificate_number','issue_date','informant','copies','ssn_last4','file_path','uploaded_on'])) then
      raise exception 'Unexpected field in the death certificate details';
    end if;
    if coalesce(p->'death_cert'->>'ssn_last4', '') !~ '^(\d{4})?$' then raise exception 'Enter only the last four digits of the Social Security number'; end if;
  end if;
  if p ? 'heirs' and jsonb_typeof(p->'heirs') <> 'array' then raise exception 'heirs must be a list'; end if;
  if p ? 'decedent_aka' and jsonb_typeof(p->'decedent_aka') <> 'array' then raise exception 'decedent_aka must be a list'; end if;
  if p ? 'record_search' and jsonb_typeof(p->'record_search') <> 'object' then raise exception 'record_search must be an object'; end if;
  if v_id is null then
    insert into property_transfer_cases (title, property_address, pins, property_county, legal_description, decedent_name, case_type, created_by)
      values (coalesce(p->>'title', ''), p->>'property_address', p->>'pins', p->>'property_county', p->>'legal_description', p->>'decedent_name',
              coalesce(nullif(p->>'case_type', ''), 'death_transfer'), auth.jwt()->>'email')
      returning id into v_id;
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
    heirs = case when p ? 'heirs' then coalesce(p->'heirs', '[]'::jsonb) else c.heirs end,
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
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  insert into property_transfer_audit (case_id, actor, action, changed) values (p_id, auth.jwt()->>'email', 'delete', '{}');
  delete from property_transfer_cases where id = p_id;
end $$;
revoke all on function transfer_staff_delete(uuid) from public, anon;
grant execute on function transfer_staff_delete(uuid) to authenticated;

-- The history of one case: who changed which fields and when (newest first, last 100).
create or replace function transfer_staff_audit(p_case uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'actor', a.actor, 'action', a.action, 'changed', a.changed) order by a.at desc)
                     from (select * from property_transfer_audit where case_id = p_case order by at desc limit 100) a), '[]'::jsonb);
end $$;
revoke all on function transfer_staff_audit(uuid) from public, anon;
grant execute on function transfer_staff_audit(uuid) to authenticated;
