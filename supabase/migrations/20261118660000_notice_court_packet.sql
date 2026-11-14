-- Court filing packet for a served pay-or-vacate notice (11/9/2026, Stephen): the notice, the stamped USPS certified
-- mail receipt and the RENT ledger go to the court together. Late fees are never part of a filing (CLAUDE.md), so the
-- ledger is the Rent Income lines only; its balance equals lease_rent_due().

create or replace function notice_court_packet(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n record;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select x.*, l.tenants_label, l.account_number, u.address into n
  from notices x join leases l on l.id = x.lease_id left join rental_units u on u.id = l.unit_id
  where x.id = p_id and x.status = 'sent' and not x.voided;
  if n.id is null then raise exception 'Notice not found (or not a sent lease notice).'; end if;
  return jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'pdf_path', n.pdf_path, 'proof_path', n.proof_path,
    'service_method', n.service_method, 'served_on', n.served_on, 'service_note', n.service_note, 'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on,
    'tenants', n.tenants_label, 'account_number', n.account_number, 'address', n.address,
    'rent_due', lease_rent_due(n.lease_id, current_date),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('date', e.entry_date, 'description', coalesce(nullif(e.description, ''), e.raw_type, e.kind),
        'check_number', e.check_number, 'amount', e.amount) order by e.entry_date, e.id)
      from lease_ledger_entries e where e.lease_id = n.lease_id and e.gl_account = 'Rent Income'), '[]'::jsonb));
end;
$$;
revoke all on function notice_court_packet(uuid) from public, anon;
grant execute on function notice_court_packet(uuid) to authenticated;
