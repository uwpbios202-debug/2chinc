-- Parking-and-keys-only login for the occupant of an owner-direct unit (Unit 6) (Stephen, 11/4/2026).
--   Rule change: Unit 6's tenant gets a login with access to ONLY Parking and Keys. Still no tenants / leases row, no rent, payments,
--   ledger or requests. The owner (John Wamser) adds or removes the person in his owner portal and sends them the sign-in details himself
--   (no email is sent by the system). They sign in at https://2ndchinc.org/unit-access/ with the emailed 6-digit code.
--   Staff screens do not list these people; their name and email are used only for sign-in and parking alerts.
-- New table: explicit grants (Supabase change of 10/30/2026).

create table if not exists unit_occupants (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  name text,
  email text not null,
  active boolean not null default true,
  added_by text,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create unique index if not exists unit_occupants_email_active on unit_occupants (lower(email)) where active;
alter table unit_occupants enable row level security;
revoke all on unit_occupants from public, anon, authenticated;
grant all on unit_occupants to service_role;

create or replace function owner_direct_unit_list()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(trim(x)), '{}') from unnest(string_to_array(condo_setting('owner_direct_units', ''), ',')) x where trim(x) <> '';
$$;
revoke all on function owner_direct_unit_list() from public, anon, authenticated;

-- The units the signed-in parking-and-keys occupant lives in.
create or replace function occupant_my_units()
returns setof text
language sql stable security definer set search_path = public as $$
  select o.unit_number from unit_occupants o
   where o.active and lower(o.email) = lower(auth.email()) and condo_session_ok() and o.unit_number = any (owner_direct_unit_list());
$$;
revoke all on function occupant_my_units() from public, anon;
grant execute on function occupant_my_units() to authenticated;

create or replace function occupant_is_me()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from unit_occupants o where o.active and lower(o.email) = lower(auth.email()) and o.unit_number = any (owner_direct_unit_list()));
$$;
revoke all on function occupant_is_me() from public, anon;
grant execute on function occupant_is_me() to authenticated;

-- Sign-in: the code email goes to them too.
do $$ declare v text := pg_get_functiondef('condo_email_on_file'::regproc); n text; begin
  n := replace(v, 'or exists (select 1 from caseworkers where active and lower(email) = lower(p_email));',
                  'or exists (select 1 from caseworkers where active and lower(email) = lower(p_email))
      or exists (select 1 from unit_occupants where active and lower(email) = lower(p_email));');
  if n = v then raise exception 'condo_email_on_file changed; update this migration'; end if;
  execute n;
end $$;

-- Who am I: role 'occupant' (only when the person is nothing else).
do $$ declare v text := pg_get_functiondef('condo_whoami'::regproc); n text; begin
  n := replace(v, '  v_caseworker boolean := caseworker_is_me();', '  v_caseworker boolean := caseworker_is_me();
  v_occupant boolean := occupant_is_me();');
  n := replace(n, 'or v_seller or v_caseworker) then', 'or v_seller or v_caseworker or v_occupant) then');
  n := replace(n, 'when v_caseworker then ''caseworker'' else ''investor'' end,', 'when v_caseworker then ''caseworker'' when v_occupant and not v_investor then ''occupant'' else ''investor'' end,');
  n := replace(n, '    union all select name, 6 from caseworkers where active and lower(email) = lower(auth.email())',
                  '    union all select name, 6 from caseworkers where active and lower(email) = lower(auth.email())
    union all select name, 7 from unit_occupants where active and lower(email) = lower(auth.email())');
  if n = v or position('or v_occupant) then' in n) = 0 or position('v_occupant boolean' in n) = 0 or position('''occupant''' in n) = 0 or position('name, 7 from unit_occupants' in n) = 0 then
    raise exception 'condo_whoami changed; update this migration';
  end if;
  execute n;
end $$;

do $$ declare v text := pg_get_functiondef('session_role'::regproc); n text; begin
  n := replace(v, '              when caseworker_is_me() then ''caseworker''', '              when caseworker_is_me() then ''caseworker''
              when occupant_is_me() and not investor_is_me() then ''occupant''');
  if n = v then raise exception 'session_role changed; update this migration'; end if;
  execute n;
end $$;

-- Parking map and lot: they may view it.
create or replace function vehicle_can_view()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from vehicle_my_units())
    or exists (select 1 from occupant_my_units())
    or condo_owner_for_email(auth.email()) is not null
    or condo_is_staff());
$$;

-- Their stall is "theirs" on the map (switches, alerts and tow requests work as for a tenant).
create or replace function parking_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u where exists (select 1 from parking_stalls s where s.home_unit = u and s.active)
  union
  select u, 'tenant' from occupant_my_units() u where exists (select 1 from parking_stalls s where s.home_unit = u and s.active)
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and cu.occupancy = 'owner' and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and exists (select 1 from parking_stalls st where st.home_unit = cu.unit_number and st.active);
$$;

-- They get parking alerts like everyone who lives here.
create or replace function parking_unit_people(p_unit text)
returns table (name text, email text, kind text)
language sql stable security definer set search_path = public as $$
  select t.name, lower(t.email), 'tenant' from leases l join rental_units ru on ru.id = l.unit_id
    join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
   where l.status = 'active' and ru.unit_number = p_unit
  union
  select o.name, lower(o.email), 'owner' from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current
    join condo_owners o on o.id = s.owner_id
   where cu.unit_number = p_unit and cu.occupancy = 'owner'
  union
  select u.name, lower(u.email), 'occupant' from unit_occupants u where u.active and u.unit_number = p_unit and u.unit_number = any (owner_direct_unit_list());
$$;
revoke all on function parking_unit_people(text) from public, anon, authenticated;

-- Keys: their building's shared codes and their unit's codes.
create or replace function key_my_units()
returns setof text
language sql stable security definer set search_path = public as $$
  select u from vehicle_my_units() u
  union
  select u from occupant_my_units() u
  union
  select cu.unit_number from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and cu.unit_number <> all (owner_no_tenant_unit_list());
$$;

-- Phone alerts open their own page.
create or replace function push_from_email()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'parking_alert' and exists (select 1 from push_subscriptions where lower(email) = lower(new.to_email)) then
    insert into push_outbox (to_email, title, body, url, tag, kind)
    values (lower(new.to_email), '🚨 ' || new.subject,
      'If it is yours or your guest''s, move it now. Tap to open the parking lot.',
      case when exists (select 1 from tenants where lower(email) = lower(new.to_email)) then '/resident/#parking'
           when exists (select 1 from unit_occupants where active and lower(email) = lower(new.to_email)) then '/unit-access/#parking'
           else '/association-owners/roca1/#parking' end,
      'parking', new.kind);
  end if;
  return new;
end;
$$;

-- Owner portal (John): see, add and remove the parking-and-keys person for his owner-direct unit(s).
create or replace function owner_occupants_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(cu.unit_number order by cu.unit_number::int) from condo_ownerships s join condo_units cu on cu.id = s.unit_id
                       where s.is_current and s.owner_id = v_owner and cu.unit_number = any (owner_direct_unit_list())), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'unit', o.unit_number, 'name', o.name, 'email', o.email, 'since', o.created_at,
                          'signed_in', exists (select 1 from auth.users u where lower(u.email) = lower(o.email) and u.last_sign_in_at is not null)) order by o.created_at)
                        from unit_occupants o where o.active and o.unit_number in (select cu.unit_number from condo_ownerships s join condo_units cu on cu.id = s.unit_id
                          where s.is_current and s.owner_id = v_owner)), '[]'::jsonb));
end;
$$;
revoke all on function owner_occupants_mine() from public, anon;
grant execute on function owner_occupants_mine() to authenticated;

create or replace function owner_occupant_add(p_unit text, p_name text, p_email text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_email text := lower(trim(coalesce(p_email, '')));
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  if not (p_unit = any (owner_direct_unit_list()) and exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id
            where s.is_current and s.owner_id = v_owner and cu.unit_number = p_unit)) then
    raise exception 'You can add a person only for your own owner-managed unit.' using errcode = '42501';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Enter the person''s name.'; end if;
  if (select count(*) from unit_occupants where active and unit_number = p_unit) >= 4 then raise exception 'Up to 4 people per unit.'; end if;
  if exists (select 1 from unit_occupants where active and lower(email) = v_email) then raise exception 'That email already has parking and keys access.'; end if;
  insert into unit_occupants (unit_number, name, email, added_by) values (p_unit, trim(p_name), v_email, lower(auth.email()));
end;
$$;
revoke all on function owner_occupant_add(text, text, text) from public, anon;
grant execute on function owner_occupant_add(text, text, text) to authenticated;

create or replace function owner_occupant_remove(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  update unit_occupants o set active = false, ended_at = now()
   where o.id = p_id and o.active and o.unit_number in (select cu.unit_number from condo_ownerships s join condo_units cu on cu.id = s.unit_id
                                                          where s.is_current and s.owner_id = v_owner);
  if not found then raise exception 'Not found.'; end if;
  -- Their phone alerts stop too.
  delete from push_subscriptions p where lower(p.email) = (select lower(email) from unit_occupants where id = p_id)
    and not exists (select 1 from unit_occupants o2 where o2.active and lower(o2.email) = lower(p.email));
end;
$$;
revoke all on function owner_occupant_remove(uuid) from public, anon;
grant execute on function owner_occupant_remove(uuid) to authenticated;
