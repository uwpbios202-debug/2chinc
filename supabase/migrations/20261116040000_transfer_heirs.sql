-- Heirs on a property transfer case: everyone who may have a share (spouse, children, a deceased child's children, parents, siblings,
-- people named in a will). Each person is added with an Add button on the case page and carries a relationship, an address for the
-- court notice, whether they are living, whether notice was mailed, and whether they receive the property under the court's order.
-- heirs_check records that the attorney confirmed the list is complete.
alter table property_transfer_cases add column if not exists heirs jsonb not null default '[]'::jsonb;
alter table property_transfer_cases add column if not exists heirs_check jsonb not null default '{}'::jsonb;

create or replace function transfer_staff_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p ? 'todi_recorded' and p->>'todi_recorded' not in ('yes','no','unknown') then raise exception 'todi_recorded must be yes, no or unknown'; end if;
  if p ? 'death_cert' and coalesce(p->'death_cert'->>'ssn_last4', '') !~ '^(\d{4})?$' then raise exception 'Enter only the last four digits of the Social Security number'; end if;
  if p ? 'heirs' and jsonb_typeof(p->'heirs') <> 'array' then raise exception 'heirs must be a list'; end if;
  if v_id is null then
    insert into property_transfer_cases (title, property_address, pins, property_county, legal_description, decedent_name, case_type, created_by)
      values (coalesce(p->>'title', ''), p->>'property_address', p->>'pins', p->>'property_county', p->>'legal_description', p->>'decedent_name',
              coalesce(nullif(p->>'case_type', ''), 'death_transfer'), auth.jwt()->>'email')
      returning id into v_id;
  end if;
  update property_transfer_cases c set
    title = case when p ? 'title' then coalesce(p->>'title', '') else c.title end,
    property_address = case when p ? 'property_address' then p->>'property_address' else c.property_address end,
    pins = case when p ? 'pins' then p->>'pins' else c.pins end,
    property_county = case when p ? 'property_county' then p->>'property_county' else c.property_county end,
    legal_description = case when p ? 'legal_description' then p->>'legal_description' else c.legal_description end,
    decedent_name = case when p ? 'decedent_name' then p->>'decedent_name' else c.decedent_name end,
    date_of_death = case when p ? 'date_of_death' then nullif(p->>'date_of_death', '')::date else c.date_of_death end,
    death_cert = case when p ? 'death_cert' then coalesce(p->'death_cert', '{}'::jsonb) else c.death_cert end,
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
    updated_at = now()
  where c.id = v_id;
  return v_id;
end $$;
revoke all on function transfer_staff_save(jsonb) from public, anon;
grant execute on function transfer_staff_save(jsonb) to authenticated;
