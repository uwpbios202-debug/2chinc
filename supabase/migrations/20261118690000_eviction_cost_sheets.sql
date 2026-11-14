-- Eviction expense sheets (Stephen, 11/10/2026): the Milwaukee County eviction expense checklist he made 11/9, kept in the database
-- and editable on https://2ndchinc.org/staff/eviction-costs/ . One TEMPLATE sheet (new sheets start from it) and one sheet per case
-- (optionally tied to a lease). Office staff only, with the authenticator code. A budgeting tool, not legal advice.

create table if not exists eviction_sheets (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  is_template boolean not null default false,
  lease_id uuid references leases(id) on delete set null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text
);
create unique index if not exists eviction_sheets_one_template on eviction_sheets (is_template) where is_template;

create table if not exists eviction_sheet_items (
  id uuid primary key default gen_random_uuid(),
  sheet_id uuid not null references eviction_sheets(id) on delete cascade,
  sort int not null default 0,
  expense text not null default '',
  covers text not null default '',
  status text not null default 'Variable',
  kind text not null default 'var' check (kind in ('actual', 'official', 'var')),
  amount numeric(12,2) not null default 0 check (amount >= 0),
  note text not null default ''
);
create index if not exists eviction_sheet_items_sheet on eviction_sheet_items (sheet_id, sort);

alter table eviction_sheets enable row level security;
alter table eviction_sheet_items enable row level security;
-- New tables need explicit grants (10/30/2026). The staff page reaches them only through the functions below.
revoke all on table eviction_sheets, eviction_sheet_items from public, anon, authenticated;
grant all on table eviction_sheets, eviction_sheet_items to service_role;

create or replace function eviction_staff_check()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff only.' using errcode = '42501'; end if;
end;
$$;
revoke all on function eviction_staff_check() from public, anon, authenticated;

-- All sheets (template first), with totals, plus leases to tie a new sheet to.
create or replace function eviction_sheets_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform eviction_staff_check();
  return jsonb_build_object(
    'sheets', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'is_template', s.is_template, 'lease_id', s.lease_id,
        'unit', ru.unit_number, 'updated_at', s.updated_at,
        'total', (select coalesce(sum(i.amount), 0) from eviction_sheet_items i where i.sheet_id = s.id))
        order by s.is_template desc, s.updated_at desc)
      from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id), '[]'::jsonb),
    'leases', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'unit', ru.unit_number, 'tenants', l.tenants_label, 'status', l.status)
        order by nullif(regexp_replace(ru.unit_number, '\D', '', 'g'), '')::int nulls last, l.start_date desc)
      from leases l join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')), '[]'::jsonb));
end;
$$;
revoke all on function eviction_sheets_list() from public, anon;
grant execute on function eviction_sheets_list() to authenticated;

create or replace function eviction_sheet_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s eviction_sheets;
begin
  perform eviction_staff_check();
  select * into s from eviction_sheets where id = p_id;
  if s.id is null then raise exception 'That sheet isn''t on file.'; end if;
  return to_jsonb(s) || jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'expense', i.expense, 'covers', i.covers,
      'status', i.status, 'kind', i.kind, 'amount', i.amount, 'note', i.note) order by i.sort) from eviction_sheet_items i where i.sheet_id = p_id), '[]'::jsonb));
end;
$$;
revoke all on function eviction_sheet_get(uuid) from public, anon;
grant execute on function eviction_sheet_get(uuid) to authenticated;

-- Save a sheet: title, lease, note and the whole list of rows (rows are replaced in the order given).
create or replace function eviction_sheet_save(p_id uuid, p_title text, p_lease uuid, p_note text, p_items jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare r jsonb; n int := 0;
begin
  perform eviction_staff_check();
  if not exists (select 1 from eviction_sheets where id = p_id) then raise exception 'That sheet isn''t on file.'; end if;
  if length(coalesce(trim(p_title), '')) < 2 then raise exception 'Give the sheet a name.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then raise exception 'The rows could not be read.'; end if;
  update eviction_sheets set title = left(trim(p_title), 120),
    lease_id = case when is_template then null else p_lease end,
    note = nullif(left(trim(coalesce(p_note, '')), 2000), ''), updated_at = now(), updated_by = lower(auth.email())
  where id = p_id;
  delete from eviction_sheet_items where sheet_id = p_id;
  for r in select * from jsonb_array_elements(p_items) loop
    n := n + 1;
    insert into eviction_sheet_items (sheet_id, sort, expense, covers, status, kind, amount, note)
    values (p_id, n, left(coalesce(r->>'expense', ''), 200), left(coalesce(r->>'covers', ''), 500), left(coalesce(nullif(r->>'status', ''), 'Variable'), 60),
      case when r->>'kind' in ('actual', 'official', 'var') then r->>'kind' else 'var' end,
      greatest(round(coalesce(nullif(r->>'amount', '')::numeric, 0), 2), 0), left(coalesce(r->>'note', ''), 2000));
  end loop;
  return eviction_sheet_get(p_id);
end;
$$;
revoke all on function eviction_sheet_save(uuid, text, uuid, text, jsonb) from public, anon;
grant execute on function eviction_sheet_save(uuid, text, uuid, text, jsonb) to authenticated;

-- New sheet for a case: a copy of the template (or of another sheet).
create or replace function eviction_sheet_new(p_title text, p_lease uuid, p_from uuid)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; v_from uuid := coalesce(p_from, (select id from eviction_sheets where is_template));
begin
  perform eviction_staff_check();
  if length(coalesce(trim(p_title), '')) < 2 then raise exception 'Give the sheet a name.'; end if;
  insert into eviction_sheets (title, lease_id, updated_by) values (left(trim(p_title), 120), p_lease, lower(auth.email())) returning id into v_id;
  insert into eviction_sheet_items (sheet_id, sort, expense, covers, status, kind, amount, note)
  select v_id, sort, expense, covers, status, kind, amount, note from eviction_sheet_items where sheet_id = v_from;
  return v_id;
end;
$$;
revoke all on function eviction_sheet_new(text, uuid, uuid) from public, anon;
grant execute on function eviction_sheet_new(text, uuid, uuid) to authenticated;

create or replace function eviction_sheet_delete(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform eviction_staff_check();
  if exists (select 1 from eviction_sheets where id = p_id and is_template) then raise exception 'The template can''t be deleted.'; end if;
  delete from eviction_sheets where id = p_id;
end;
$$;
revoke all on function eviction_sheet_delete(uuid) from public, anon;
grant execute on function eviction_sheet_delete(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The template: Stephen's 11/9/2026 checklist (fees checked 11/9/2026; court fees changed 11/1/2026, 2025 Wis. Act 179).
do $$
declare v_id uuid;
begin
  if exists (select 1 from eviction_sheets where is_template) then return; end if;
  insert into eviction_sheets (title, is_template, note, updated_by) values ('Template: Milwaukee County eviction expenses', true,
    'Fees checked Nov 9, 2026. Court fees changed Nov 1, 2026 (2025 Wis. Act 179). Confirm with the Clerk of Circuit Court (414-278-4140) and Sheriff Civil Process (414-278-5030) before filing. Sources: USPS eReceipt 11/06/2026; Milwaukee County Sheriff Civil Process fee list; court fee schedule effective Nov 1, 2026 (Wis. Stat. 814.62, 814.85, 814.86); costs taxable in a judgment: Wis. Stat. 799.25. A budgeting tool, not legal advice.',
    'info@2ndchinc.org')
  returning id into v_id;
  insert into eviction_sheet_items (sheet_id, sort, expense, covers, status, kind, amount, note) values
  (v_id, 1, 'Notice preparation', '5-day or 14-day notice, as applicable', 'Variable', 'var', 0, 'Enter your cost (forms, printing, staff time).'),
  (v_id, 2, 'Notice delivery', 'Personal delivery, mailing, or other legally permitted method', 'Variable', 'var', 0, ''),
  (v_id, 3, 'Certified mailing', 'USPS postage and additional services', 'Actual receipt', 'actual', 6.37, 'USPS eReceipt 11/06/2026: $0.82 First-Class postage + $5.55 Certified Mail. The receipt total of $24.41 also includes a $16.40 Flag booklet and $2.46 of Love stamps (2 of 3 unused), which are stamp stock, not this mailing.'),
  (v_id, 4, 'Court filing', 'Filing eviction complaint in small claims court', 'County fee', 'official', 131.50, 'Milwaukee County, filed on/after 11/1/2026: $39 filing + $61 court support + $24 justice info + $7.50 Milwaukee surcharge = $131.50 (was $98.00 before 11/1).'),
  (v_id, 5, 'Summons service', 'Sheriff or authorized process server', 'Additional fee', 'official', 100, 'Sheriff list: $100 for legal papers (summons), covers up to 3 attempts. Alternative: clerk mailing at $7 per defendant plus certified postage (certified is required for eviction). Confirm whether the $100 is per defendant.'),
  (v_id, 6, 'Additional defendants', 'Separate service attempts where required', 'Variable', 'var', 0, 'Each extra defendant: about $100 by Sheriff (confirm), or $7 plus postage by clerk mail.'),
  (v_id, 7, 'Court appearances', 'Landlord''s travel and time', 'Indirect', 'var', 0, 'Parking, mileage, staff time.'),
  (v_id, 8, 'Judgment', 'Court costs awarded or assessed', 'Case-dependent', 'var', 0, 'Filing fee, service fees and writ execution charges can be taxed to the tenant in the judgment (Wis. Stat. 799.25), so some of this may be recoverable. Enter any extra clerk costs here.'),
  (v_id, 9, 'Writ of restitution', 'Obtaining authority to recover possession', 'Additional procedural cost', 'var', 0, 'The writ is obtained at the Clerk''s office (Courthouse Room G-9) after the order. Fee not confirmed. Ask the clerk and enter it here.'),
  (v_id, 10, 'Sheriff execution', 'Sheriff physically restores possession', 'Additional fee', 'official', 225, 'Sheriff list: Evictions $225 (includes a $105 process fee). Return without service: $135.'),
  (v_id, 11, 'Sheriff extra time', 'Hourly deputy time if the eviction runs long', 'Case-dependent', 'var', 0, '$60 per hour per deputy, maximum 2 deputies. Enter hours x deputies x $60.'),
  (v_id, 12, 'Locksmith', 'Changing locks after lawful recovery', 'Variable', 'var', 0, ''),
  (v_id, 13, 'Property removal', 'Moving, handling, or storing tenant property where applicable', 'Variable', 'var', 0, ''),
  (v_id, 14, 'Cleaning and repairs', 'Preparing the property for the next tenant', 'Variable', 'var', 0, ''),
  (v_id, 15, 'Lost rent', 'Rental income lost during the process and vacancy', 'Potentially substantial', 'var', 0, 'Monthly rent x months from default to re-rental.'),
  (v_id, 16, 'Advertising', 'Finding a replacement tenant', 'Variable', 'var', 0, ''),
  (v_id, 17, 'Utility expenses', 'Utilities paid while the unit is vacant', 'Variable', 'var', 0, '');
end $$;
