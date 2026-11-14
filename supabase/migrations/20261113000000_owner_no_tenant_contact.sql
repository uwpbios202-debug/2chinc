-- Owners who must not contact their tenant (Stephen, 10/13/2026: Unit 8, Frederick Haney).
-- Portal setting owner_no_tenant_units = comma list of unit numbers. For those units the owner portal shows no Tenant tab,
-- condo_my_tenants() returns nothing (so the owner-tenant-email function also refuses), and no tenant name or balance is shown.
insert into portal_settings (key, value) values ('owner_no_tenant_units', '8') on conflict (key) do nothing;

create or replace function owner_no_tenant_unit_list()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(trim(x)), '{}') from unnest(string_to_array(condo_setting('owner_no_tenant_units', ''), ',')) x where trim(x) <> '';
$$;
revoke all on function owner_no_tenant_unit_list() from public, anon, authenticated;

-- true when every unit this owner holds is switched off (the portal then hides the Tenant tab)
create or replace function owner_tenant_tab_off()
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return exists (select 1 from condo_ownerships s where s.owner_id = v_owner and s.is_current)
     and not exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id
                     where s.owner_id = v_owner and s.is_current and cu.unit_number <> all (owner_no_tenant_unit_list()));
end $$;
revoke all on function owner_tenant_tab_off() from public, anon;
grant execute on function owner_tenant_tab_off() to authenticated;

create or replace function condo_my_tenants()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'unit_number', u.unit_number, 'address', u.address,
      'tenants', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.name), '[]'::jsonb)
                  from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id),
      'balance', (select coalesce(sum(e.amount), 0) from lease_ledger_entries e where e.lease_id = l.id),
      'rent', l.rent, 'lease_start', l.start_date, 'lease_end', l.end_date)
      order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int)
    from condo_ownerships s
    join condo_units u on u.id = s.unit_id
    join rental_units ru on ru.condo_unit_id = u.id
    join leases l on l.unit_id = ru.id and l.status = 'active'
    where s.owner_id = v_owner and s.is_current and u.unit_number <> all (owner_no_tenant_unit_list())), '[]'::jsonb);
end $$;
revoke all on function condo_my_tenants() from public, anon;
grant execute on function condo_my_tenants() to authenticated;

-- Same owners also get no Guests tab / guest approval (Stephen, 10/13/2026).
create or replace function guest_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and coalesce(cu.occupancy, '') <> 'owner' and cu.unit_number <> all (owner_direct_unit_list())
     and cu.unit_number <> all (owner_no_tenant_unit_list());
$$;
revoke all on function guest_my_units() from public, anon;
grant execute on function guest_my_units() to authenticated;

-- ...and no Keys tab / door codes for the owner (a tenant of the unit still sees their own codes).
create or replace function key_my_units()
returns setof text
language sql stable security definer set search_path = public as $$
  select u from vehicle_my_units() u
  union
  select cu.unit_number from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and cu.unit_number <> all (owner_no_tenant_unit_list());
$$;
revoke all on function key_my_units() from public, anon;
grant execute on function key_my_units() to authenticated;

-- ...and no Rent statements for the owner.
create or replace function roca_distributions_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(roca_distribution_row(d) - 'calc_by' - 'approved_by' - 'transferred_by' - 'paid_by' - 'reversed_by' - 'lease_ids' - 'terms'
      order by d.month desc, roca_unit_sort(d.unit_number))
    from roca_distributions d where d.owner_id = v_owner and d.status in ('approved', 'transferred', 'paid')
      and d.unit_number <> all (owner_no_tenant_unit_list())), '[]'::jsonb);
end;
$$;
revoke all on function roca_distributions_mine() from public, anon;
grant execute on function roca_distributions_mine() to authenticated;
