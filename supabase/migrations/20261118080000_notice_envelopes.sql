-- Envelopes for printed notices (Stephen, 11/3/2026). The Notices page prints one #10 envelope per notice: return address
-- (setting pay_by_mail, the office's mailing address) and the tenant's (or land contract buyer's) name and premises address.
-- Read-only; staff only. No new tables.
create or replace function notice_envelopes(p_ids uuid[])
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'from', coalesce(condo_setting('pay_by_mail', ''), ''),
    'list', coalesce((select jsonb_agg(x order by x->>'line1', x->>'names') from (
      select jsonb_build_object('id', n.id,
        'names', coalesce(
          (select jsonb_agg(t.name order by t.name) from lease_tenants lt join tenants t on t.id = lt.tenant_id where n.lease_id is not null and lt.lease_id = n.lease_id),
          (select jsonb_agg(t.name order by t.name) from land_contract_buyers b join tenants t on t.id = b.tenant_id where n.land_contract_id is not null and b.contract_id = n.land_contract_id),
          jsonb_build_array(coalesce(l.tenants_label, c.buyers_label, 'Occupant'))),
        'line1', case when u.id is not null
                   then trim(split_part(u.address, ' - ', 1)) || coalesce(' Unit ' || nullif(trim(u.unit_number), ''), '')
                   else cp.street end,
        'line2', coalesce(p.city, cp.city, 'Milwaukee') || ', ' || coalesce(p.state, cp.state, 'WI') || ' ' || coalesce(p.zip, cp.zip, '')) as x
      from notices n
      left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id left join rental_properties p on p.id = u.property_id
      left join land_contracts c on c.id = n.land_contract_id left join rental_properties cp on cp.id = c.property_id
      where n.id = any(p_ids)) s), '[]'::jsonb));
end $$;
revoke all on function notice_envelopes(uuid[]) from public, anon;
grant execute on function notice_envelopes(uuid[]) to authenticated, service_role;
