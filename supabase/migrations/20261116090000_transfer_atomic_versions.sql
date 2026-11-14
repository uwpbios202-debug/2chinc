-- Property transfer: closing the version loopholes found in review.
--  * Changing an existing case, heir, creditor or document now REQUIRES the version the caller read, and the UPDATE itself carries the version test
--    (update ... where version = expected), so two callers holding the same version can no longer both succeed.
--  * Deeds get a version and an approval (who approved it for signing, and when). A deed with no approval is a draft: the PDF says so on every page.
--  * The death-certificate details may keep a list of earlier uploaded files (previous_files) so a replaced certificate is not lost.
alter table quitclaim_deeds add column if not exists version int not null default 0;
alter table quitclaim_deeds add column if not exists approved_by text;
alter table quitclaim_deeds add column if not exists approved_on date;

create or replace function deed_staff_save(p jsonb, p_save_legal boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_unit uuid := nullif(p->>'unit_id', '')::uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(p->>'template', 'cook') not in ('cook','peoria') then raise exception 'Unknown deed layout'; end if;
  if v_id is null then
    insert into quitclaim_deeds (template, unit_id, title, prepared_by, return_to, mail_to, taxpayer, grantors, grantor_city, grantor_county,
        grantees, grantee_city, grantee_county, ownership_form, consideration, legal_description, pin, property_address, property_county,
        exempt_letter, deed_date, approved_by, approved_on, created_by)
      values (coalesce(p->>'template', 'cook'), v_unit, coalesce(p->>'title', ''), p->>'prepared_by', p->>'return_to', p->>'mail_to', p->>'taxpayer',
        coalesce(p->'grantors', '[]'::jsonb), p->>'grantor_city', p->>'grantor_county', coalesce(p->'grantees', '[]'::jsonb), p->>'grantee_city',
        p->>'grantee_county', p->>'ownership_form', p->>'consideration', p->>'legal_description', p->>'pin', p->>'property_address',
        p->>'property_county', p->>'exempt_letter', nullif(p->>'deed_date', '')::date, nullif(trim(coalesce(p->>'approved_by', '')), ''), nullif(p->>'approved_on', '')::date, auth.jwt()->>'email')
      returning id into v_id;
  else
    if not (p ? 'version') then raise exception 'A version is required to change an existing deed'; end if;
    update quitclaim_deeds set template = coalesce(p->>'template', template), unit_id = v_unit, title = coalesce(p->>'title', ''),
        prepared_by = p->>'prepared_by', return_to = p->>'return_to', mail_to = p->>'mail_to', taxpayer = p->>'taxpayer',
        grantors = coalesce(p->'grantors', '[]'::jsonb), grantor_city = p->>'grantor_city', grantor_county = p->>'grantor_county',
        grantees = coalesce(p->'grantees', '[]'::jsonb), grantee_city = p->>'grantee_city', grantee_county = p->>'grantee_county',
        ownership_form = p->>'ownership_form', consideration = p->>'consideration', legal_description = p->>'legal_description',
        pin = p->>'pin', property_address = p->>'property_address', property_county = p->>'property_county',
        exempt_letter = p->>'exempt_letter', deed_date = nullif(p->>'deed_date', '')::date,
        approved_by = nullif(trim(coalesce(p->>'approved_by', '')), ''), approved_on = nullif(p->>'approved_on', '')::date,
        version = version + 1, updated_at = now()
      where id = v_id and version = (p->>'version')::int;
    if not found then
      if exists (select 1 from quitclaim_deeds where id = v_id) then raise exception 'This deed was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
      raise exception 'Deed not found';
    end if;
  end if;
  if p_save_legal and v_unit is not null then
    update condo_units set legal_description = nullif(trim(coalesce(p->>'legal_description', '')), '') where id = v_unit;
  end if;
  return v_id;
end $$;
revoke all on function deed_staff_save(jsonb, boolean) from public, anon;
grant execute on function deed_staff_save(jsonb, boolean) to authenticated;

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
    if coalesce(v_exists, false) and not (p ? 'version') then raise exception 'A version is required to change an existing row'; end if;
    if false then raise exception 'This person was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    v_extra := p - array['id','name','relationship','living','address','phone','email','notice','notice_on','tracking','receives','share','version','case_id','position'];
    if coalesce(trim(p->>'name'), '') = '' then raise exception 'A name is required'; end if;
    if coalesce(v_exists, false) then
      update property_transfer_heirs set name = p->>'name', relationship = p->>'relationship', living = nullif(p->>'living',''), address = p->>'address', phone = p->>'phone', email = p->>'email',
        notice = nullif(p->>'notice',''), notice_on = nullif(p->>'notice_on','')::date, tracking = p->>'tracking', receives = coalesce((p->>'receives')::boolean, false), share = p->>'share',
        extra = v_extra, version = version + 1, updated_at = now(), updated_by = v_who where id = v_id and case_id = p_case and version = (p->>'version')::int returning * into h;
      if not found then raise exception 'This row was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    else
      select coalesce(p_position, coalesce(max(position), -1) + 1) into v_pos from property_transfer_heirs where case_id = p_case;
      insert into property_transfer_heirs (id, case_id, position, name, relationship, living, address, phone, email, notice, notice_on, tracking, receives, share, extra, updated_by)
        values (v_id, p_case, v_pos, p->>'name', p->>'relationship', nullif(p->>'living',''), p->>'address', p->>'phone', p->>'email', nullif(p->>'notice',''), nullif(p->>'notice_on','')::date, p->>'tracking',
                coalesce((p->>'receives')::boolean, false), p->>'share', v_extra, v_who) returning * into h;
    end if;
    out := transfer_heir_json(h);
  elsif p_kind = 'creditors' then
    select true, version into v_exists, v_ver from property_transfer_creditors where id = v_id and case_id = p_case;
    if coalesce(v_exists, false) and not (p ? 'version') then raise exception 'A version is required to change an existing row'; end if;
    if false then raise exception 'This creditor was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    v_extra := p - array['id','name','address','amount','claim','notice','tracking','mailed_on','version','case_id','position'];
    if coalesce(trim(p->>'name'), '') = '' then raise exception 'A name is required'; end if;
    if coalesce(v_exists, false) then
      update property_transfer_creditors set name = p->>'name', address = p->>'address', amount = p->>'amount', claim = coalesce(nullif(p->>'claim',''), 'potential'), notice = coalesce(nullif(p->>'notice',''), 'none'),
        tracking = p->>'tracking', mailed_on = nullif(p->>'mailed_on','')::date, extra = v_extra, version = version + 1, updated_at = now(), updated_by = v_who where id = v_id and case_id = p_case and version = (p->>'version')::int returning * into c;
      if not found then raise exception 'This row was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    else
      select coalesce(p_position, coalesce(max(position), -1) + 1) into v_pos from property_transfer_creditors where case_id = p_case;
      insert into property_transfer_creditors (id, case_id, position, name, address, amount, claim, notice, tracking, mailed_on, extra, updated_by)
        values (v_id, p_case, v_pos, p->>'name', p->>'address', p->>'amount', coalesce(nullif(p->>'claim',''), 'potential'), coalesce(nullif(p->>'notice',''), 'none'), p->>'tracking', nullif(p->>'mailed_on','')::date, v_extra, v_who) returning * into c;
    end if;
    out := transfer_creditor_json(c);
  else
    select true, version into v_exists, v_ver from property_transfer_documents where id = v_id and case_id = p_case;
    if coalesce(v_exists, false) and not (p ? 'version') then raise exception 'A version is required to change an existing row'; end if;
    if false then raise exception 'This document was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
    v_extra := p - array['id','folder','name','form','status','sig','ref','expected','where','path','on','recheck','custom','version','case_id','position'];
    if coalesce(trim(p->>'name'), '') = '' then raise exception 'A name is required'; end if;
    if coalesce(v_exists, false) then
      update property_transfer_documents set folder = p->>'folder', name = p->>'name', form = p->>'form', status = coalesce(nullif(p->>'status',''), 'todo'), sig = (p->>'sig')::boolean, ref = p->>'ref',
        expected = nullif(p->>'expected','')::date, where_kept = p->>'where', path = p->>'path', scan_on = nullif(p->>'on','')::date, recheck = coalesce((p->>'recheck')::boolean, false),
        custom = coalesce((p->>'custom')::boolean, false), extra = v_extra, version = version + 1, updated_at = now(), updated_by = v_who where id = v_id and case_id = p_case and version = (p->>'version')::int returning * into d;
      if not found then raise exception 'This row was changed somewhere else. Reload the page and try again.' using errcode = '40001'; end if;
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
    if exists (select 1 from jsonb_object_keys(p->'death_cert') k where k <> all (array['residence_address','legal_name','date_of_birth','place_of_death','county_of_residence','marital_status','surviving_spouse','certificate_number','issue_date','informant','copies','ssn_last4','file_path','uploaded_on','previous_files'])) then
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
  elsif not (p ? 'expected_version') then
    raise exception 'A version is required to change an existing case';
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
  where c.id = v_id and (v_new or c.version = (p->>'expected_version')::int);
  if not found then
    if exists (select 1 from property_transfer_cases where id = v_id) then raise exception 'This case was changed somewhere else since you opened it. Reload the page and try again.' using errcode = '40001'; end if;
    raise exception 'Case not found';
  end if;
  select coalesce(array_agg(k order by k), '{}') into v_changed from jsonb_object_keys(p) k where k not in ('id', 'expected_version');
  insert into property_transfer_audit (case_id, actor, action, changed) values (v_id, auth.jwt()->>'email', case when v_new then 'create' else 'update' end, v_changed);
  return v_id;
end $$;

revoke all on function transfer_row_save_one(text, uuid, jsonb, int) from public, anon;
revoke all on function transfer_staff_save(jsonb) from public, anon;
grant execute on function transfer_staff_save(jsonb) to authenticated;
