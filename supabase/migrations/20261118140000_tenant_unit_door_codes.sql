-- Tenants add their own unit entry door key code(s) (Stephen, 11/3/2026).
--   A tenant with an active lease (every unit except Unit 6, which has no tenant in this system) enters the key code for their unit's
--   entry door on the Keys tab of the resident portal, one at a time, up to 3 per unit (most units have one). The glass entry door is
--   already on file and is not entered here. Each code saved emails info@2ndchinc.org (the email never contains the code: codes live
--   only in key_codes, see 20261112040000_keys_system.sql). No codes are written in this file.
-- A unit may now hold more than one code for the same key point: key_codes.slot (1 to 3). Every other key point keeps slot 1 only.
-- No new table, so no new grants are needed (Supabase change of 10/30/2026).

alter table key_codes add column if not exists slot smallint not null default 1;
alter table key_codes drop constraint if exists key_codes_slot_check;
alter table key_codes add constraint key_codes_slot_check check (slot between 1 and 3);
drop index if exists key_codes_one_per_unit;
create unique index if not exists key_codes_one_per_unit_slot on key_codes (point_id, coalesce(unit_number, ''), slot);
alter table key_log add column if not exists slot smallint;

-- The key point tenants fill in: the unit entry door key.
create or replace function key_unit_entry_point()
returns uuid
language sql stable security definer set search_path = public as $$
  select id from key_points where kind = 'unit' and audience = 'unit' and active order by sort, created_at limit 1;
$$;
revoke all on function key_unit_entry_point() from public, anon, authenticated;
grant execute on function key_unit_entry_point() to service_role;

-- Residents and owners: same as before, now with the slot (a second or third entry door code shows as "Unit entry door key 2", "3").
create or replace function keys_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_units text[];
begin
  select coalesce(array_agg(u), '{}') into v_units from key_my_units() u;
  if cardinality(v_units) = 0 then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', p.name || case when c.slot > 1 then ' ' || c.slot else '' end, 'building', p.building, 'kind', p.kind,
             'unit', c.unit_number, 'slot', c.slot, 'code', c.code, 'note', p.note, 'updated_at', c.updated_at) order by p.sort, p.name, c.unit_number, c.slot)
    from key_points p join key_codes c on c.point_id = p.id
    where p.active and (
      (p.audience = 'building' and (p.building = 'both' or exists (
         select 1 from condo_units cu where cu.unit_number = any (v_units) and split_part(cu.address, ' ', 1) = p.building)))
      or (p.audience = 'unit' and c.unit_number = any (v_units)))
  ), '[]'::jsonb);
end;
$$;
revoke all on function keys_mine() from public, anon;
grant execute on function keys_mine() to authenticated;

-- Tenant: what the add-a-code form needs (no codes returned here; keys_mine shows them).
create or replace function keys_tenant_status()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_unit text; v_point uuid := key_unit_entry_point();
begin
  select u into v_unit from vehicle_my_units() u join condo_units cu on cu.unit_number = u where u <> '6' order by u limit 1;
  if v_unit is null or v_point is null then return jsonb_build_object('can_add', false); end if;
  return jsonb_build_object('can_add', true, 'unit', v_unit,
    'count', (select count(*) from key_codes where point_id = v_point and unit_number = v_unit), 'max', 3);
end;
$$;
revoke all on function keys_tenant_status() from public, anon;
grant execute on function keys_tenant_status() to authenticated;

-- Tenant: add one unit entry door key code (the next free slot, up to 3). Emails info@ that a code was added (without the code).
create or replace function keys_tenant_add_code(p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_unit text; v_point uuid := key_unit_entry_point(); v_slot int; v_code text := trim(coalesce(p_code, '')); v_n int;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select u into v_unit from vehicle_my_units() u join condo_units cu on cu.unit_number = u where u <> '6' order by u limit 1;
  if v_unit is null then raise exception 'Only a tenant with an active lease can add a door code.' using errcode = '42501'; end if;
  if v_point is null then raise exception 'Door codes cannot be added right now. Please call the office.'; end if;
  if length(v_code) < 1 or length(v_code) > 40 then raise exception 'Type the code that is on your key (up to 40 characters).'; end if;
  if exists (select 1 from key_codes where point_id = v_point and unit_number = v_unit and lower(code) = lower(v_code)) then
    raise exception 'That code is already on file for your unit.';
  end if;
  select min(s) into v_slot from generate_series(1, 3) s
   where not exists (select 1 from key_codes where point_id = v_point and unit_number = v_unit and slot = s);
  if v_slot is null then raise exception 'Your unit already has 3 door codes on file. To change one, please contact the office.'; end if;
  insert into key_codes (point_id, unit_number, slot, code, updated_by) values (v_point, v_unit, v_slot, v_code, auth.email());
  insert into key_log (point_id, unit_number, slot, action, by_email) values (v_point, v_unit, v_slot, 'code added by tenant', auth.email());
  select count(*) into v_n from key_codes where point_id = v_point and unit_number = v_unit;
  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org',
    'Unit ' || v_unit || ': tenant added a unit entry door key code',
    '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>A tenant of <b>Unit ' || v_unit || '</b> added a unit entry door key code'
    || case when v_slot > 1 then ' (code ' || v_slot || ')' else '' end || ' in the resident portal on '
    || to_char(now() at time zone 'America/Chicago', 'FMMM/FMDD/YYYY at FMHH12:MI AM') || '.</p>'
    || '<p>Unit ' || v_unit || ' now has ' || v_n || ' entry door code' || case when v_n = 1 then '' else 's' end || ' on file.</p>'
    || '<p>For security the code is not in this email. See it on the Keys page: <a href="https://2ndchinc.org/staff/keys/">https://2ndchinc.org/staff/keys/</a></p>'
    || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing</p></div>', 'key_code_added');
  return jsonb_build_object('slot', v_slot, 'count', v_n, 'max', 3);
end;
$$;
revoke all on function keys_tenant_add_code(text) from public, anon;
grant execute on function keys_tenant_add_code(text) to authenticated;

-- Staff: list now carries the slot; set and remove take it (default 1, so the other key points work as before).
create or replace function keys_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'building', p.building, 'kind', p.kind,
        'audience', p.audience, 'note', p.note, 'sort', p.sort, 'active', p.active,
        'codes', coalesce((select jsonb_agg(jsonb_build_object('unit', c.unit_number, 'slot', c.slot, 'code', c.code, 'updated_at', c.updated_at, 'updated_by', c.updated_by)
                   order by nullif(regexp_replace(coalesce(c.unit_number, '0'), '\D', '', 'g'), '')::int, c.slot) from key_codes c where c.point_id = p.id), '[]'::jsonb))
        order by p.sort, p.name) from key_points p), '[]'::jsonb),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', unit_number, 'building', split_part(address, ' ', 1), 'occupancy', occupancy)
        order by nullif(regexp_replace(unit_number, '\D', '', 'g'), '')::int) from condo_units), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(x) from (select l.at, l.by_email, l.action, l.unit_number, l.slot, p.name from key_log l left join key_points p on p.id = l.point_id
        order by l.at desc limit 30) x), '[]'::jsonb));
end;
$$;
revoke all on function keys_staff_list() from public, anon;
grant execute on function keys_staff_list() to authenticated;

drop function if exists keys_staff_set_code(uuid, text, text);
create or replace function keys_staff_set_code(p_point uuid, p_unit text, p_code text, p_slot int default 1)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_new boolean; v_slot int := coalesce(p_slot, 1);
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from key_points where id = p_point) then raise exception 'Key point not found'; end if;
  if v_slot not between 1 and 3 then raise exception 'Code number must be 1 to 3.'; end if;
  if length(coalesce(trim(p_code), '')) < 1 or length(p_code) > 40 then raise exception 'Enter the code (up to 40 characters).'; end if;
  v_new := not exists (select 1 from key_codes where point_id = p_point and coalesce(unit_number, '') = coalesce(nullif(trim(p_unit), ''), '') and slot = v_slot);
  insert into key_codes (point_id, unit_number, slot, code, updated_by) values (p_point, nullif(trim(p_unit), ''), v_slot, trim(p_code), auth.email())
  on conflict (point_id, (coalesce(unit_number, '')), slot) do update set code = excluded.code, updated_at = now(), updated_by = excluded.updated_by;
  insert into key_log (point_id, unit_number, slot, action, by_email) values (p_point, nullif(trim(p_unit), ''), v_slot, case when v_new then 'code added' else 'code changed' end, auth.email());
end;
$$;
revoke all on function keys_staff_set_code(uuid, text, text, int) from public, anon;
grant execute on function keys_staff_set_code(uuid, text, text, int) to authenticated;

drop function if exists keys_staff_clear_code(uuid, text);
create or replace function keys_staff_clear_code(p_point uuid, p_unit text, p_slot int default 1)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_slot int := coalesce(p_slot, 1);
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from key_codes where point_id = p_point and coalesce(unit_number, '') = coalesce(nullif(trim(p_unit), ''), '') and slot = v_slot;
  insert into key_log (point_id, unit_number, slot, action, by_email) values (p_point, nullif(trim(p_unit), ''), v_slot, 'code removed', auth.email());
end;
$$;
revoke all on function keys_staff_clear_code(uuid, text, int) from public, anon;
grant execute on function keys_staff_clear_code(uuid, text, int) to authenticated;
