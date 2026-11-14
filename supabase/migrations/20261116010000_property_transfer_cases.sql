-- Property transfer after a death: one case per property, walked step by step at https://2ndchinc.org/staff/deeds/transfer/
-- (the owner of record died; the heir needs to become the deed owner). The case holds the property, what the recorder search found,
-- the heir's own choice of name, the legal path (TODI recorded or probate) and the status of every step. The deed itself
-- stays in quitclaim_deeds (https://2ndchinc.org/staff/deeds/); the case links to it. Staff only, through the functions below.
create table if not exists property_transfer_cases (
  id uuid primary key default gen_random_uuid(),
  title text not null default '',
  property_address text,
  pins text,                                   -- one or more parcel numbers
  property_county text,
  legal_description text,
  decedent_name text,                          -- the owner of record who died
  decedent_aka jsonb not null default '[]'::jsonb,
  date_of_death date,
  owner_of_record_doc text,                    -- recorded document that put the decedent on title
  record_search jsonb not null default '{}'::jsonb,  -- {searched_on, indexed_through, findings:[{doc,type,recorded,parties,note}]}
  todi_recorded text not null default 'unknown' check (todi_recorded in ('yes','no','unknown')),
  heir_candidates jsonb not null default '[]'::jsonb, -- [{name, source}] names seen in records, offered to the heir to pick from
  heir_name text,                              -- the heir's own choice
  heir_name_how text check (heir_name_how in ('chosen','typed','spoken')),
  representative text,                         -- probate path: court-appointed representative, once there is one
  deed_id uuid references quitclaim_deeds(id) on delete set null,
  steps jsonb not null default '{}'::jsonb,    -- {stepId: {status, note, done_on}}
  notes text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table property_transfer_cases enable row level security;
grant select, insert, update, delete on property_transfer_cases to service_role;

create or replace function transfer_staff_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(c) order by c.updated_at desc) from property_transfer_cases c), '[]'::jsonb);
end $$;
revoke all on function transfer_staff_list() from public, anon;
grant execute on function transfer_staff_list() to authenticated;

-- Insert (no id) or update (with id). Only the fields sent are changed, so a step tick does not overwrite the rest.
create or replace function transfer_staff_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p ? 'todi_recorded' and p->>'todi_recorded' not in ('yes','no','unknown') then raise exception 'todi_recorded must be yes, no or unknown'; end if;
  if v_id is null then
    insert into property_transfer_cases (title, property_address, pins, property_county, legal_description, decedent_name, created_by)
      values (coalesce(p->>'title', ''), p->>'property_address', p->>'pins', p->>'property_county', p->>'legal_description', p->>'decedent_name', auth.jwt()->>'email')
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
    todi_recorded = case when p ? 'todi_recorded' then p->>'todi_recorded' else c.todi_recorded end,
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

create or replace function transfer_staff_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from property_transfer_cases where id = p_id;
end $$;
revoke all on function transfer_staff_delete(uuid) from public, anon;
grant execute on function transfer_staff_delete(uuid) to authenticated;
