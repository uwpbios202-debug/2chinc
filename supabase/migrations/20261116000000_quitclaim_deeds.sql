-- Quit claim deeds: staff fill a deed from saved data and print the PDF (https://2ndchinc.org/staff/deeds/).
-- The PDF is drawn in the browser from the saved row; nothing leaves the office. Two layouts, both Illinois statutory:
-- 'cook' (Cook County style) and 'peoria' (Peoria County style). Staff only, through the functions below.

-- The legal description belongs to the property, so it is typed once and copied onto each deed (still editable per deed).
alter table condo_units add column if not exists legal_description text;

create table if not exists quitclaim_deeds (
  id uuid primary key default gen_random_uuid(),
  template text not null default 'cook' check (template in ('cook','peoria')),
  unit_id uuid references condo_units(id) on delete set null,
  title text not null default '',               -- staff label for the list, not printed
  prepared_by text,                             -- peoria: "This document prepared by"
  return_to text,                               -- peoria: "Return document to"
  mail_to text,                                 -- cook: "Mail to" (lines)
  taxpayer text,                                -- cook: name and address of tax payer (lines)
  grantors jsonb not null default '[]'::jsonb,  -- up to 4 names
  grantor_city text,
  grantor_county text,
  grantees jsonb not null default '[]'::jsonb,  -- up to 4 names
  grantee_city text,
  grantee_county text,
  ownership_form text,                          -- peoria: "in the form of ownership"
  consideration text,
  legal_description text,
  pin text,
  property_address text,
  property_county text,
  exempt_letter text,                           -- peoria: 35 ILCS 200/31-45 paragraph
  deed_date date,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table quitclaim_deeds enable row level security;
grant select, insert, update, delete on quitclaim_deeds to service_role;

-- Units with their address, PIN, saved legal description and current owners (names only), to prefill a new deed.
create or replace function deed_staff_units() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', u.id, 'unit', u.unit_number, 'address', u.address, 'pin', u.pin, 'legal', u.legal_description,
      'owners', coalesce((select jsonb_agg(o.name order by o.name) from condo_ownerships s join condo_owners o on o.id = s.owner_id
                           where s.unit_id = u.id and s.is_current), '[]'::jsonb)) order by u.unit_number) from condo_units u), '[]'::jsonb);
end $$;
revoke all on function deed_staff_units() from public, anon;
grant execute on function deed_staff_units() to authenticated;

create or replace function deed_staff_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.updated_at desc) from quitclaim_deeds d), '[]'::jsonb);
end $$;
revoke all on function deed_staff_list() from public, anon;
grant execute on function deed_staff_list() to authenticated;

-- Insert (no id) or update (with id). p_save_legal also stores the legal description on the unit for next time.
create or replace function deed_staff_save(p jsonb, p_save_legal boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_unit uuid := nullif(p->>'unit_id', '')::uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(p->>'template', 'cook') not in ('cook','peoria') then raise exception 'Unknown deed layout'; end if;
  if v_id is null then
    insert into quitclaim_deeds (template, unit_id, title, prepared_by, return_to, mail_to, taxpayer, grantors, grantor_city, grantor_county,
        grantees, grantee_city, grantee_county, ownership_form, consideration, legal_description, pin, property_address, property_county,
        exempt_letter, deed_date, created_by)
      values (coalesce(p->>'template', 'cook'), v_unit, coalesce(p->>'title', ''), p->>'prepared_by', p->>'return_to', p->>'mail_to', p->>'taxpayer',
        coalesce(p->'grantors', '[]'::jsonb), p->>'grantor_city', p->>'grantor_county', coalesce(p->'grantees', '[]'::jsonb), p->>'grantee_city',
        p->>'grantee_county', p->>'ownership_form', p->>'consideration', p->>'legal_description', p->>'pin', p->>'property_address',
        p->>'property_county', p->>'exempt_letter', nullif(p->>'deed_date', '')::date, auth.jwt()->>'email')
      returning id into v_id;
  else
    update quitclaim_deeds set template = coalesce(p->>'template', template), unit_id = v_unit, title = coalesce(p->>'title', ''),
        prepared_by = p->>'prepared_by', return_to = p->>'return_to', mail_to = p->>'mail_to', taxpayer = p->>'taxpayer',
        grantors = coalesce(p->'grantors', '[]'::jsonb), grantor_city = p->>'grantor_city', grantor_county = p->>'grantor_county',
        grantees = coalesce(p->'grantees', '[]'::jsonb), grantee_city = p->>'grantee_city', grantee_county = p->>'grantee_county',
        ownership_form = p->>'ownership_form', consideration = p->>'consideration', legal_description = p->>'legal_description',
        pin = p->>'pin', property_address = p->>'property_address', property_county = p->>'property_county',
        exempt_letter = p->>'exempt_letter', deed_date = nullif(p->>'deed_date', '')::date, updated_at = now()
      where id = v_id;
    if not found then raise exception 'Deed not found'; end if;
  end if;
  if p_save_legal and v_unit is not null then
    update condo_units set legal_description = nullif(trim(coalesce(p->>'legal_description', '')), '') where id = v_unit;
  end if;
  return v_id;
end $$;
revoke all on function deed_staff_save(jsonb, boolean) from public, anon;
grant execute on function deed_staff_save(jsonb, boolean) to authenticated;

create or replace function deed_staff_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from quitclaim_deeds where id = p_id;
end $$;
revoke all on function deed_staff_delete(uuid) from public, anon;
grant execute on function deed_staff_delete(uuid) to authenticated;
