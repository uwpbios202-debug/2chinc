-- Owner portal: the tenants living in the units an owner owns.
-- An owner sees each current tenant's NAME and the lease BALANCE only. No email,
-- phone or ledger lines; messages go through the owner-tenant-email function,
-- which looks the address up itself.

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
    where s.owner_id = v_owner and s.is_current), '[]'::jsonb);
end $$;
revoke all on function condo_my_tenants() from public, anon;
grant execute on function condo_my_tenants() to authenticated;
