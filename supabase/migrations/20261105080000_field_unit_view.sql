-- Unit view for staff who are assigned to specific units (Stephen, 10/6/2026).
-- They see EVERYTHING about their units, read-only: the tenant side (lease, balance and ledger, maintenance requests,
-- notices, move-in and move-out status, work in lieu, vehicles) and the owner side (owner, association balance and ledger),
-- plus inspections. Nothing in this function pays, records, posts or changes anything, and the page that shows it has no
-- payment controls. Office staff can use it too.
create or replace function field_unit_view(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ru uuid; v_lease uuid; v_cu condo_units; v_acct uuid; v_addr text; v_res jsonb;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  v_ru := inspection_rental_unit(p_property, p_unit);
  select ru.address into v_addr from rental_units ru where ru.id = v_ru;
  select l.id into v_lease from leases l where l.unit_id = v_ru and l.status = 'active' order by l.start_date desc nulls last limit 1;
  select * into v_cu from condo_units where unit_number = p_unit;
  select a.id into v_acct from condo_ledger_accounts a where a.unit_id = v_cu.id and a.billing_account and not a.excluded limit 1;

  v_res := jsonb_build_object(
    'unit', jsonb_build_object('property_id', p_property, 'unit', p_unit, 'address', coalesce(v_addr, v_cu.address), 'occupancy', v_cu.occupancy, 'pin', v_cu.pin,
        'bedrooms', v_cu.bedrooms, 'bathrooms', v_cu.bathrooms, 'size_sqft', v_cu.size_sqft),
    'lease', (select jsonb_build_object('id', l.id, 'status', l.status, 'type', l.lease_type, 'rent', l.rent, 'start_date', l.start_date, 'end_date', l.end_date,
          'deposit_held', l.deposit_held, 'late_fee', l.late_fee, 'keys_released_at', l.keys_released_at,
          'balance', coalesce((select sum(e.amount) from lease_ledger_entries e where e.lease_id = l.id and e.gl_account = 'Rent Income'), 0),
          'tenants', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone, 'alt_phone', t.alt_phone, 'emergency_name', t.emergency_name,
                 'emergency_phone', t.emergency_phone) order by t.name) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id), '[]'::jsonb))
        from leases l where l.id = v_lease),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('date', x.entry_date, 'kind', x.kind, 'description', x.description, 'amount', x.amount, 'note', x.correction_note) order by x.entry_date desc, x.id desc)
        from (select * from lease_ledger_entries where lease_id = v_lease order by entry_date desc, id desc limit 60) x), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('number', r.number, 'subject', r.subject, 'status', r.status, 'category', r.category, 'created_at', r.created_at,
        'scheduled_start', r.scheduled_start, 'vendor', (select v.name from vendors v where v.id = r.vendor_id), 'description', r.description, 'entry', r.entry_permission) order by r.created_at desc)
        from (select * from maintenance_requests where lease_id = v_lease order by created_at desc limit 30) r), '[]'::jsonb),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('subject', n.subject, 'template', n.template_name, 'sent_at', n.sent_at, 'status', n.status, 'served_on', n.served_on, 'voided', n.voided) order by n.sent_at desc)
        from (select * from notices where lease_id = v_lease order by sent_at desc limit 30) n), '[]'::jsonb),
    'move_in', (select jsonb_build_object('status', m.status, 'submitted_at', m.submitted_at) from move_in_checklists m where m.lease_id = v_lease),
    'move_out', (select jsonb_build_object('status', m.status, 'type', m.type, 'move_out_date', m.move_out_date, 'notice_received_at', m.notice_received_at) from move_outs m where m.lease_id = v_lease order by m.notice_received_at desc nulls last limit 1),
    'work', coalesce((select jsonb_agg(jsonb_build_object('title', w.title, 'kind', w.kind, 'status', w.status, 'monthly_credit', w.monthly_credit, 'job_value', w.job_value, 'credit_month', w.credit_month,
        'tasks', w.tasks, 'accepted_at', w.accepted_at) order by w.created_at) from work_agreements w where w.lease_id = v_lease), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) - 'lease_id' - 'tenant_id' - 'registered_by' || jsonb_build_object('summary', vehicle_summary(v)) order by v.created_at desc) from vehicles v where v.unit_number = p_unit and v.status = 'active'), '[]'::jsonb),
    'inspections', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'inspected_on', i.inspected_on, 'status', i.status, 'inspector', i.inspector_email,
        'needs_repair', (select count(*) from jsonb_each(i.data -> 'items') e where e.value ->> 's' = 'Needs repair')) order by i.inspected_on desc)
        from inspections i where i.property_id = p_property and i.unit = p_unit), '[]'::jsonb),
    'owner', (select jsonb_build_object('name', o.name, 'email', o.email, 'phone', o.phone_mobile, 'since', s.start_date, 'board_position', s.board_position,
          'balance', coalesce((select sum(e.amount) from condo_ledger_entries e join condo_ledger_accounts a2 on a2.id = e.account_id where a2.ownership_id = s.id and not a2.excluded), 0),
          'dues', s.fee)
        from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.unit_id = v_cu.id and s.is_current limit 1),
    'owner_ledger', coalesce((select jsonb_agg(jsonb_build_object('date', x.entry_date, 'kind', x.kind, 'description', x.description, 'amount', x.amount) order by x.entry_date desc, x.id desc)
        from (select * from condo_ledger_entries where account_id = v_acct order by entry_date desc, id desc limit 40) x), '[]'::jsonb));
  return v_res;
end;
$$;
revoke all on function field_unit_view(text, text) from public, anon;
grant execute on function field_unit_view(text, text) to authenticated;

-- Staff assigned to a unit can see that unit's vehicle photos (the tenant's car, loaner or regular visitor).
create or replace function vehicle_can_view_unit(p_unit text)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from vehicle_my_units())
    or condo_owner_for_email(auth.email()) is not null
    or condo_is_staff()
    or (field_is_staff() and exists (select 1 from staff_units where lower(email) = lower(auth.email()) and unit = p_unit)));
$$;
revoke all on function vehicle_can_view_unit(text) from public, anon;
grant execute on function vehicle_can_view_unit(text) to authenticated;
drop policy if exists "vehicles read residents owners staff" on storage.objects;
create policy "vehicles read residents owners staff" on storage.objects for select to authenticated
  using (bucket_id = 'vehicles' and vehicle_can_view_unit((storage.foldername(name))[1]));
