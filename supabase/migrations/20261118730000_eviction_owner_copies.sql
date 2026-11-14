-- Eviction costs: each owner gets their OWN editable copy per unit (Stephen, 11/11/2026, "option A"), for Units 15, 16 and 17.
-- The copy starts from the office template; the owner edits amounts, notes and rows on the owner portal (#eviction). Their edits never
-- change the office template or another owner's copy. The office sees and can edit every copy at https://2ndchinc.org/staff/eviction-costs/ .
-- Sheets the office ties to a lease on the owner's unit stay read-only for the owner.

update portal_settings set value = '15,16,17' where key = 'eviction_sheet_owner_units';
insert into portal_settings (key, value) values ('eviction_sheet_owner_units', '15,16,17') on conflict (key) do nothing;

alter table eviction_sheets add column if not exists owner_unit text;
create unique index if not exists eviction_sheets_one_owner_copy on eviction_sheets (owner_unit) where owner_unit is not null;

-- Rows replaced in the order given (shared by the office save and the owner save).
create or replace function eviction_items_replace(p_id uuid, p_items jsonb)
returns void language plpgsql volatile security definer set search_path = public as $$
declare r jsonb; n int := 0;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then raise exception 'The rows could not be read.'; end if;
  delete from eviction_sheet_items where sheet_id = p_id;
  for r in select * from jsonb_array_elements(p_items) loop
    n := n + 1;
    insert into eviction_sheet_items (sheet_id, sort, expense, covers, status, kind, amount, note)
    values (p_id, n, left(coalesce(r->>'expense', ''), 200), left(coalesce(r->>'covers', ''), 500), left(coalesce(nullif(r->>'status', ''), 'Variable'), 60),
      case when r->>'kind' in ('actual', 'official', 'var') then r->>'kind' else 'var' end,
      greatest(round(coalesce(nullif(r->>'amount', '')::numeric, 0), 2), 0), left(coalesce(r->>'note', ''), 2000));
  end loop;
end;
$$;
revoke all on function eviction_items_replace(uuid, jsonb) from public, anon, authenticated;

-- Sheets an owner may see: their unit copies and sheets tied to a lease on their units (no longer the template itself).
create or replace function eviction_owner_can_see(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select cardinality(eviction_owner_units_mine()) > 0 and exists (
    select 1 from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id
     where s.id = p_id and (s.owner_unit = any (eviction_owner_units_mine()) or ru.unit_number = any (eviction_owner_units_mine())));
$$;
revoke all on function eviction_owner_can_see(uuid) from public, anon, authenticated;

-- The owner's sheets. Makes the unit copy from the template the first time (hence volatile).
drop function if exists eviction_sheets_mine();
create function eviction_sheets_mine()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_units text[] := eviction_owner_units_mine(); v_u text; v_id uuid; v_tpl uuid := (select id from eviction_sheets where is_template);
begin
  if cardinality(v_units) = 0 then return jsonb_build_object('allowed', false, 'sheets', '[]'::jsonb); end if;
  foreach v_u in array v_units loop
    if v_tpl is not null and not exists (select 1 from eviction_sheets where owner_unit = v_u) then
      insert into eviction_sheets (title, owner_unit, note, updated_by)
        select 'Unit ' || v_u || ' eviction budget', v_u, t.note, 'copied from the office template' from eviction_sheets t where t.id = v_tpl
        on conflict do nothing returning id into v_id;
      if v_id is not null then
        insert into eviction_sheet_items (sheet_id, sort, expense, covers, status, kind, amount, note)
        select v_id, sort, expense, covers, status, kind, amount, note from eviction_sheet_items where sheet_id = v_tpl;
      end if;
      v_id := null;
    end if;
  end loop;
  return jsonb_build_object('allowed', true, 'units', to_jsonb(v_units), 'sheets', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'editable', s.owner_unit is not null,
        'unit', coalesce(s.owner_unit, ru.unit_number), 'note', s.note, 'updated_at', s.updated_at,
        'items', coalesce((select jsonb_agg(jsonb_build_object('expense', i.expense, 'covers', i.covers, 'status', i.status, 'kind', i.kind, 'amount', i.amount, 'note', i.note)
                           order by i.sort) from eviction_sheet_items i where i.sheet_id = s.id), '[]'::jsonb))
      order by (s.owner_unit is null), coalesce(s.owner_unit, ru.unit_number), s.updated_at desc)
    from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id
   where s.owner_unit = any (v_units) or (s.owner_unit is null and not s.is_template and ru.unit_number = any (v_units))), '[]'::jsonb));
end;
$$;
revoke all on function eviction_sheets_mine() from public, anon;
grant execute on function eviction_sheets_mine() to authenticated;

-- Owner saves their unit copy: note and rows (the name stays "Unit N eviction budget").
create or replace function eviction_owner_sheet_save(p_id uuid, p_note text, p_items jsonb)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from eviction_sheets where id = p_id and owner_unit = any (eviction_owner_units_mine())) then
    raise exception 'You can''t change this sheet.' using errcode = '42501'; end if;
  perform eviction_items_replace(p_id, p_items);
  update eviction_sheets set note = nullif(left(trim(coalesce(p_note, '')), 2000), ''), updated_at = now(), updated_by = lower(auth.email()) where id = p_id;
end;
$$;
revoke all on function eviction_owner_sheet_save(uuid, text, jsonb) from public, anon;
grant execute on function eviction_owner_sheet_save(uuid, text, jsonb) to authenticated;

-- Owner resets their copy back to the office template.
create or replace function eviction_owner_sheet_reset(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare v_tpl uuid := (select id from eviction_sheets where is_template);
begin
  if not exists (select 1 from eviction_sheets where id = p_id and owner_unit = any (eviction_owner_units_mine())) then
    raise exception 'You can''t change this sheet.' using errcode = '42501'; end if;
  delete from eviction_sheet_items where sheet_id = p_id;
  insert into eviction_sheet_items (sheet_id, sort, expense, covers, status, kind, amount, note)
  select p_id, sort, expense, covers, status, kind, amount, note from eviction_sheet_items where sheet_id = v_tpl;
  update eviction_sheets set note = (select note from eviction_sheets where id = v_tpl), updated_at = now(), updated_by = lower(auth.email()) where id = p_id;
end;
$$;
revoke all on function eviction_owner_sheet_reset(uuid) from public, anon;
grant execute on function eviction_owner_sheet_reset(uuid) to authenticated;

-- Office list: show the owner copies with their unit.
create or replace function eviction_sheets_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform eviction_staff_check();
  return jsonb_build_object(
    'sheets', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'is_template', s.is_template, 'lease_id', s.lease_id,
        'unit', coalesce(ru.unit_number, s.owner_unit), 'owner_copy', s.owner_unit is not null, 'updated_at', s.updated_at,
        'total', (select coalesce(sum(i.amount), 0) from eviction_sheet_items i where i.sheet_id = s.id))
        order by s.is_template desc, s.updated_at desc)
      from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id), '[]'::jsonb),
    'leases', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'unit', ru.unit_number, 'tenants', l.tenants_label, 'status', l.status)
        order by nullif(regexp_replace(ru.unit_number, '\D', '', 'g'), '')::int nulls last, l.start_date desc)
      from leases l join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')), '[]'::jsonb),
    'owners', coalesce((select jsonb_agg(jsonb_build_object('unit', cu.unit_number, 'name', o.name, 'email', o.email) order by cu.unit_number)
      from condo_ownerships co join condo_units cu on cu.id = co.unit_id join condo_owners o on o.id = co.owner_id
     where co.end_date is null and coalesce(o.email, '') <> ''
       and cu.unit_number = any (string_to_array(replace(coalesce((select value from portal_settings where key = 'eviction_sheet_owner_units'), ''), ' ', ''), ','))), '[]'::jsonb));
end;
$$;
revoke all on function eviction_sheets_list() from public, anon;
grant execute on function eviction_sheets_list() to authenticated;

-- Office save: an owner copy keeps its name and stays off any lease.
create or replace function eviction_sheet_save(p_id uuid, p_title text, p_lease uuid, p_note text, p_items jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform eviction_staff_check();
  if not exists (select 1 from eviction_sheets where id = p_id) then raise exception 'That sheet isn''t on file.'; end if;
  if length(coalesce(trim(p_title), '')) < 2 then raise exception 'Give the sheet a name.'; end if;
  perform eviction_items_replace(p_id, p_items);
  update eviction_sheets set title = case when owner_unit is not null then title else left(trim(p_title), 120) end,
    lease_id = case when is_template or owner_unit is not null then null else p_lease end,
    note = nullif(left(trim(coalesce(p_note, '')), 2000), ''), updated_at = now(), updated_by = lower(auth.email())
  where id = p_id;
  return eviction_sheet_get(p_id);
end;
$$;
revoke all on function eviction_sheet_save(uuid, text, uuid, text, jsonb) from public, anon;
grant execute on function eviction_sheet_save(uuid, text, uuid, text, jsonb) to authenticated;
