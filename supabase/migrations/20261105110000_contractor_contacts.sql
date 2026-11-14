-- Contractors may contact the tenant directly to get the work done (Stephen, 10/6/2026): the job now shows the tenant's name and
-- phone number for the unit so they can call or text to set a time. Entry rules (yes / call first / no) still apply and are shown.
create or replace function contractor_tasks()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from contractor_me()) then raise exception 'Contractor sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'number', r.number, 'subject', r.subject, 'description', r.description, 'category', r.category, 'status', r.status,
      'unit', coalesce(ru.unit_number, r.unit_label), 'address', coalesce(ru.address, p.street, r.unit_label),
      'scheduled_start', r.scheduled_start, 'scheduled_end', r.scheduled_end, 'entry_permission', r.entry_permission, 'entry_purpose', r.entry_purpose,
      'has_pets', r.has_pets, 'pets_note', r.pets_note, 'photo_count', cardinality(r.photos), 'notes', r.contractor_notes, 'created_at', r.created_at,
      'tenants', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'phone', t.phone) order by t.name) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = r.lease_id), '[]'::jsonb))
      order by (r.status in ('completed', 'closed')), r.scheduled_start nulls last, r.created_at)
    from maintenance_requests r
    left join leases l on l.id = r.lease_id left join rental_units ru on ru.id = l.unit_id left join rental_properties p on p.id = ru.property_id
    where r.vendor_id in (select contractor_me())
      and (r.status not in ('completed', 'closed') or coalesce(r.closed_at, r.contractor_updated_at, r.updated_at) > now() - interval '30 days')), '[]'::jsonb);
end;
$$;
revoke all on function contractor_tasks() from public, anon;
grant execute on function contractor_tasks() to authenticated;
