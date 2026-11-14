-- Owner-direct units: the owner's private tenant information (Stephen, 10/12/2026).
--
-- Unit 6 (John Wamser) is owner-direct managed: 2nd Chance does not manage its tenant, so there is NO tenant record for it
-- (no `tenants` or `leases` row, and none is wanted). John keeps whatever he sees fit about his tenant here, in his own
-- portal, and CHOOSES whether staff can see it: "Keep private" (the default) or "Publish to staff".
-- While private, no staff function returns it. Staff see it only while he has published it, and only the fields below.
-- Which units work this way is the portal setting `owner_direct_units` (today: 6).
-- Locked like the rest of the schema: RLS on, no policies, everything through the functions below.

insert into portal_settings (key, value) values ('owner_direct_units', '6') on conflict (key) do nothing;

create table if not exists owner_direct_tenants (
  id bigint generated always as identity primary key,
  owner_id uuid not null references condo_owners(id),
  unit_number text not null,
  tenant_names text,
  phone text,
  email text,
  move_in date,
  lease_start date,
  lease_end date,
  monthly_rent numeric(12,2),
  security_deposit numeric(12,2),
  notes text,
  published boolean not null default false,
  published_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (owner_id, unit_number)
);
alter table owner_direct_tenants enable row level security;

create or replace function owner_direct_unit_list()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(trim(x)), '{}') from unnest(string_to_array(condo_setting('owner_direct_units', ''), ',')) x where trim(x) <> '';
$$;
revoke all on function owner_direct_unit_list() from public, anon, authenticated;

-- Owner: their owner-direct units and what they have saved (empty form when nothing yet).
create or replace function owner_direct_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('units', coalesce((
    select jsonb_agg(jsonb_build_object('unit', cu.unit_number, 'address', cu.address,
        'saved', (select to_jsonb(t) - 'id' - 'owner_id' from owner_direct_tenants t where t.owner_id = v_owner and t.unit_number = cu.unit_number))
      order by cu.unit_number)
    from condo_ownerships s join condo_units cu on cu.id = s.unit_id
    where s.is_current and s.owner_id = v_owner and cu.unit_number = any (owner_direct_unit_list())), '[]'::jsonb));
end;
$$;
revoke all on function owner_direct_mine() from public, anon;
grant execute on function owner_direct_mine() to authenticated;

-- Owner: save the information and the publish choice in one step.
create or replace function owner_direct_save(p_unit text, p_names text, p_phone text, p_email text, p_move_in date, p_lease_start date,
  p_lease_end date, p_rent numeric, p_deposit numeric, p_notes text, p_published boolean)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_was boolean;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id
                 where s.is_current and s.owner_id = v_owner and cu.unit_number = p_unit and p_unit = any (owner_direct_unit_list())) then
    raise exception 'This page is not available for that unit.';
  end if;
  select published into v_was from owner_direct_tenants where owner_id = v_owner and unit_number = p_unit;
  insert into owner_direct_tenants (owner_id, unit_number, tenant_names, phone, email, move_in, lease_start, lease_end, monthly_rent, security_deposit, notes, published, published_at)
  values (v_owner, p_unit, nullif(trim(p_names), ''), nullif(trim(p_phone), ''), nullif(trim(p_email), ''), p_move_in, p_lease_start, p_lease_end, p_rent, p_deposit,
          nullif(trim(p_notes), ''), coalesce(p_published, false), case when coalesce(p_published, false) then now() end)
  on conflict (owner_id, unit_number) do update set tenant_names = excluded.tenant_names, phone = excluded.phone, email = excluded.email, move_in = excluded.move_in,
    lease_start = excluded.lease_start, lease_end = excluded.lease_end, monthly_rent = excluded.monthly_rent, security_deposit = excluded.security_deposit,
    notes = excluded.notes, published = excluded.published,
    published_at = case when excluded.published then coalesce(case when v_was then owner_direct_tenants.published_at end, now()) end, updated_at = now();
end;
$$;
revoke all on function owner_direct_save(text, text, text, text, date, date, date, numeric, numeric, text, boolean) from public, anon;
grant execute on function owner_direct_save(text, text, text, text, date, date, date, numeric, numeric, text, boolean) to authenticated;

-- Staff: ONLY what the owner has chosen to publish. Nothing at all while it is private.
create or replace function owner_direct_published(p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return (select jsonb_build_object('unit', t.unit_number, 'owner', (select name from condo_owners where id = t.owner_id), 'tenant_names', t.tenant_names,
            'phone', t.phone, 'email', t.email, 'move_in', t.move_in, 'lease_start', t.lease_start, 'lease_end', t.lease_end,
            'monthly_rent', t.monthly_rent, 'security_deposit', t.security_deposit, 'notes', t.notes, 'published_at', t.published_at, 'updated_at', t.updated_at)
          from owner_direct_tenants t where t.unit_number = p_unit and t.published limit 1);
end;
$$;
revoke all on function owner_direct_published(text) from public, anon;
grant execute on function owner_direct_published(text) to authenticated;

-- Owner-direct units have no guest approval either (the owner handles their own tenant); owner-occupied units, as before.
create or replace function guest_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and coalesce(cu.occupancy, '') <> 'owner' and cu.unit_number <> all (owner_direct_unit_list());
$$;
revoke all on function guest_my_units() from public, anon;
grant execute on function guest_my_units() to authenticated;
