-- Owner profile for office staff (Stephen, 10/6/2026): one place for everything about an owner.
-- Contact details, every unit they own or owned, balances and account history, collections, violations, staff notes,
-- board terms, payment reports, emails we sent, messages, the tenants and vehicles at their units, and every change
-- to their information. Read only; editing contact details still goes through condo_staff_update_owner.
create or replace function owner_staff_profile(p_owner uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o condo_owners; v_units text[]; v_emails text[];
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into o from condo_owners where id = p_owner;
  if o.id is null then raise exception 'Owner not found'; end if;
  select coalesce(array_agg(u.unit_number order by u.unit_number), '{}') into v_units
    from condo_ownerships s join condo_units u on u.id = s.unit_id where s.owner_id = o.id and s.is_current;
  v_emails := array_remove(array[lower(o.email), lower(o.alt_email)], null);

  return jsonb_build_object(
    'owner', to_jsonb(o) - 'legacy_ids' || jsonb_build_object('units', condo_unit_label(o.id), 'is_current', cardinality(v_units) > 0),
    'ownerships', coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_number, 'address', u.address, 'pin', u.pin, 'occupancy', u.occupancy, 'start', s.start_date, 'end', s.end_date,
          'current', s.is_current, 'dues', s.fee, 'board_position', s.board_position,
          'balance', coalesce((select sum(e.amount) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id where a.ownership_id = s.id and not a.excluded), 0),
          'last_payment', (select jsonb_build_object('date', e.entry_date, 'amount', -e.amount) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                           where a.ownership_id = s.id and e.kind = 'payment' order by e.entry_date desc, e.id desc limit 1))
        order by s.is_current desc, s.start_date desc nulls last) from condo_ownerships s join condo_units u on u.id = s.unit_id where s.owner_id = o.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('unit', x.unit_number, 'date', x.entry_date, 'kind', x.kind, 'description', x.description, 'amount', x.amount) order by x.entry_date desc, x.id desc)
        from (select e.*, u.unit_number from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
              join condo_ownerships s on s.id = a.ownership_id where s.owner_id = o.id and s.is_current and not a.excluded order by e.entry_date desc, e.id desc limit 60) x), '[]'::jsonb),
    'collections', coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_number, 'date', c.step_date, 'step', c.step, 'amount', c.amount, 'note', c.note) order by c.step_date desc)
        from condo_collection_steps c join condo_units u on u.id = c.unit_id where u.unit_number = any (v_units)), '[]'::jsonb),
    'violations', coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_number, 'category', v.category, 'description', v.description, 'observed', v.observed_date, 'status', v.status,
          'fine', v.fine_amount, 'resolution', v.resolution_note) order by v.observed_date desc)
        from condo_violations v join condo_units u on u.id = v.unit_id where v.owner_id = o.id or u.unit_number = any (v_units)), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('at', n.created_at, 'by', n.entered_by, 'note', n.note) order by n.created_at desc) from condo_owner_notes n where n.owner_id = o.id), '[]'::jsonb),
    'board', coalesce((select jsonb_agg(jsonb_build_object('position', t.position, 'start', t.start_date, 'end', t.end_date, 'note', t.note) order by t.start_date desc nulls last) from condo_board_terms t where t.owner_id = o.id), '[]'::jsonb),
    'updates', coalesce((select jsonb_agg(jsonb_build_object('at', p.created_at, 'kind', p.kind, 'via', p.via, 'changes', p.changes) order by p.created_at desc)
        from (select * from condo_profile_updates where owner_id = o.id order by created_at desc limit 30) p), '[]'::jsonb),
    'payment_reports', coalesce((select jsonb_agg(jsonb_build_object('at', r.created_at, 'method', r.method, 'amount', r.amount, 'paid_on', r.paid_on, 'status', r.status, 'note', r.note) order by r.created_at desc)
        from (select * from payment_reports where owner_id = o.id order by created_at desc limit 20) r), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('at', x.created_at, 'to', x.to_email, 'subject', x.subject, 'kind', x.kind, 'sent', x.sent_at is not null) order by x.created_at desc)
        from (select * from email_outbox where lower(to_email) = any (v_emails) order by created_at desc limit 50) x), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'email', m.email, 'message', m.message) order by m.created_at desc)
        from contact_messages m where lower(m.email) = any (v_emails)), '[]'::jsonb),
    'tenants', coalesce((select jsonb_agg(jsonb_build_object('unit', ru.unit_number, 'tenants', l.tenants_label, 'rent', l.rent, 'since', l.start_date,
          'balance', coalesce((select sum(e.amount) from lease_ledger_entries e where e.lease_id = l.id and e.gl_account = 'Rent Income'), 0),
          'contacts', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone)) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id), '[]'::jsonb))
        order by ru.unit_number) from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = any (v_units)), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('unit', v.unit_number, 'kind', v.kind, 'summary', vehicle_summary(v)) order by v.unit_number) from vehicles v where v.status = 'active' and v.unit_number = any (v_units)), '[]'::jsonb),
    'alert_prefs', (select prefs from condo_alert_prefs where owner_id = o.id));
end;
$$;
revoke all on function owner_staff_profile(uuid) from public, anon;
grant execute on function owner_staff_profile(uuid) to authenticated;
