-- Deposit held and the original lease number on each lease (from the original
-- tenant statements, data/current/Active_Tenant_Ledgers.xlsx).
alter table leases add column if not exists deposit_held numeric(12,2);
alter table leases add column if not exists legacy_lease_number text;

create or replace function rentals_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'property', p.name, 'property_key', p.key, 'unit_number', u.unit_number, 'address', u.address,
        'managed_by', u.managed_by, 'management_note', u.management_note,
        'condo_occupancy', cu.occupancy, 'bedrooms', cu.bedrooms, 'bathrooms', cu.bathrooms, 'size_sqft', cu.size_sqft,
        'leases', coalesce((select jsonb_agg(jsonb_build_object(
            'id', l.id, 'status', l.status, 'lease_type', l.lease_type, 'start_date', l.start_date, 'end_date', l.end_date,
            'rent', l.rent, 'tenants_label', l.tenants_label, 'balance', b.balance, 'legacy_balance', l.legacy_balance,
            'entries', b.entries, 'correction_note', l.correction_note,
            'deposit_held', l.deposit_held, 'legacy_lease_number', l.legacy_lease_number,
            'work_agreements', (select count(*) from work_agreements w where w.lease_id = l.id),
            'tenants', (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone) order by t.name)
                        from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id))
            order by l.start_date desc nulls last)
          from leases l join lease_balances b on b.lease_id = l.id where l.unit_id = u.id), '[]'::jsonb))
        order by p.key <> 'roca1', p.name, nullif(regexp_replace(coalesce(u.unit_number, ''), '\D', '', 'g'), '')::int nulls last)
      from rental_units u join rental_properties p on p.id = u.property_id
      left join condo_units cu on cu.id = u.condo_unit_id), '[]'::jsonb)
  );
end;
$$;
