-- Keys system (Stephen, 10/12/2026): the door codes for 6622 and 6626 N Bourbon St.
--
-- A "key point" is a place a code works: the glass entry door, the basement electronic lock, a unit's own door.
-- Each has who may see it (audience):
--   building  everyone who lives in that building (or 'both'), tenants and owners alike (e.g. the glass entry door);
--   unit      only that unit's household: one code per unit (e.g. the basement lock gives each unit its own code);
--   staff     staff only (e.g. the lock's admin code).
-- The CODES themselves are data, entered in the staff page (https://2ndchinc.org/staff/keys/). They are never put in a
-- migration or any file in this repository. The change log records who changed what and when, never the code.
-- Locked like the rest of the schema: RLS on, no policies, everything through the functions below.

create table if not exists key_points (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  building text not null check (building in ('6622', '6626', 'both')),
  kind text not null default 'door' check (kind in ('door', 'basement', 'unit', 'other')),
  audience text not null check (audience in ('building', 'unit', 'staff')),
  note text,                               -- shown with the code, e.g. "Pull the door firmly after you enter."
  sort int not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists key_codes (
  id bigint generated always as identity primary key,
  point_id uuid not null references key_points(id) on delete cascade,
  unit_number text,                        -- null for a building-wide or staff code; the unit for a per-unit code
  code text not null,
  updated_at timestamptz not null default now(),
  updated_by text
);
create unique index if not exists key_codes_one_per_unit on key_codes (point_id, coalesce(unit_number, ''));

create table if not exists key_log (
  id bigint generated always as identity primary key,
  point_id uuid references key_points(id) on delete set null,
  unit_number text,
  action text not null,
  by_email text,
  at timestamptz not null default now()
);

alter table key_points enable row level security;
alter table key_codes enable row level security;
alter table key_log enable row level security;

-- Units the signed-in person lives in or owns (owner-occupied included).
create or replace function key_my_units()
returns setof text
language sql stable security definer set search_path = public as $$
  select u from vehicle_my_units() u
  union
  select cu.unit_number from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok();
$$;
revoke all on function key_my_units() from public, anon;
grant execute on function key_my_units() to authenticated;

-- Residents and owners: only the codes for their own building and their own unit.
create or replace function keys_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_units text[];
begin
  select coalesce(array_agg(u), '{}') into v_units from key_my_units() u;
  if cardinality(v_units) = 0 then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', p.name, 'building', p.building, 'kind', p.kind, 'unit', c.unit_number,
             'code', c.code, 'note', p.note, 'updated_at', c.updated_at) order by p.sort, p.name, c.unit_number)
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

-- Staff: every key point with every code, plus the units each building has.
create or replace function keys_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'building', p.building, 'kind', p.kind,
        'audience', p.audience, 'note', p.note, 'sort', p.sort, 'active', p.active,
        'codes', coalesce((select jsonb_agg(jsonb_build_object('unit', c.unit_number, 'code', c.code, 'updated_at', c.updated_at, 'updated_by', c.updated_by)
                   order by nullif(regexp_replace(coalesce(c.unit_number, '0'), '\D', '', 'g'), '')::int) from key_codes c where c.point_id = p.id), '[]'::jsonb))
        order by p.sort, p.name) from key_points p), '[]'::jsonb),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', unit_number, 'building', split_part(address, ' ', 1), 'occupancy', occupancy)
        order by nullif(regexp_replace(unit_number, '\D', '', 'g'), '')::int) from condo_units), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(x) from (select l.at, l.by_email, l.action, l.unit_number, p.name from key_log l left join key_points p on p.id = l.point_id
        order by l.at desc limit 30) x), '[]'::jsonb));
end;
$$;
revoke all on function keys_staff_list() from public, anon;
grant execute on function keys_staff_list() to authenticated;

-- Staff: set (or change) one code. p_unit is null for a building-wide or staff code.
create or replace function keys_staff_set_code(p_point uuid, p_unit text, p_code text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_new boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from key_points where id = p_point) then raise exception 'Key point not found'; end if;
  if length(coalesce(trim(p_code), '')) < 1 or length(p_code) > 40 then raise exception 'Enter the code (up to 40 characters).'; end if;
  v_new := not exists (select 1 from key_codes where point_id = p_point and coalesce(unit_number, '') = coalesce(nullif(trim(p_unit), ''), ''));
  insert into key_codes (point_id, unit_number, code, updated_by) values (p_point, nullif(trim(p_unit), ''), trim(p_code), auth.email())
  on conflict (point_id, (coalesce(unit_number, ''))) do update set code = excluded.code, updated_at = now(), updated_by = excluded.updated_by;
  insert into key_log (point_id, unit_number, action, by_email) values (p_point, nullif(trim(p_unit), ''), case when v_new then 'code added' else 'code changed' end, auth.email());
end;
$$;
revoke all on function keys_staff_set_code(uuid, text, text) from public, anon;
grant execute on function keys_staff_set_code(uuid, text, text) to authenticated;

-- Staff: remove one code (e.g. a unit moved out).
create or replace function keys_staff_clear_code(p_point uuid, p_unit text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from key_codes where point_id = p_point and coalesce(unit_number, '') = coalesce(nullif(trim(p_unit), ''), '');
  insert into key_log (point_id, unit_number, action, by_email) values (p_point, nullif(trim(p_unit), ''), 'code removed', auth.email());
end;
$$;
revoke all on function keys_staff_clear_code(uuid, text) from public, anon;
grant execute on function keys_staff_clear_code(uuid, text) to authenticated;

-- Staff: add a new key point (a new door or lock).
create or replace function keys_staff_add_point(p_name text, p_building text, p_audience text, p_note text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Give it a name.'; end if;
  insert into key_points (name, building, audience, note, kind)
  values (trim(p_name), p_building, p_audience, nullif(trim(p_note), ''), 'other') returning id into v_id;
  insert into key_log (point_id, action, by_email) values (v_id, 'key point added', auth.email());
  return v_id;
end;
$$;
revoke all on function keys_staff_add_point(text, text, text, text) from public, anon;
grant execute on function keys_staff_add_point(text, text, text, text) to authenticated;

-- The key points themselves (no codes here; codes are entered on the staff page).
insert into key_points (name, building, kind, audience, note, sort)
select * from (values
  ('Glass entry door key',           '6626', 'door',     'building', 'This is a key, not a keypad code. The key is stamped with the code shown here. Please do not copy it; ask the office for another.', 10),
  ('Glass entry door key',           '6622', 'door',     'building', 'This is a key, not a keypad code. The key is stamped with the code shown here. Please do not copy it; ask the office for another.', 10),
  ('Basement front door lock',       '6626', 'basement', 'unit',     'Your own unit''s secret code for the basement front door. The basement back door is exit only.', 20),
  ('Basement front door lock',       '6622', 'basement', 'unit',     'Your own unit''s secret code for the basement front door. The basement back door is exit only.', 20),
  ('Basement front door lock admin code', '6626', 'basement', 'staff', 'Programs the basement front door lock. Staff only.', 90),
  ('Unit entry door key',            'both', 'unit',     'unit',     'The key code for your own unit''s entry door. Please do not copy your key; ask the office for another.', 30)
) v(name, building, kind, audience, note, sort)
where not exists (select 1 from key_points);
