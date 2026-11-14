-- Payment fixes (10/11/2026 review): autopay no longer charges a lease that already has a fresh pending payment report (double payment);
-- the resident portal no longer receives internal ROCA/board, owner-payment, bank and cycle settings, and gets the tenant's own share of the rent (tenant_rent)
-- so an assisted tenant is not shown the full rent.

CREATE OR REPLACE FUNCTION public.autopay_due(p_as_of date)
 RETURNS TABLE(tenant_id uuid, customer_id text, payment_method text, lease_id uuid, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select distinct on (l.id) c.tenant_id, c.customer_id, c.autopay_payment_method, l.id, lease_rent_due(l.id, p_as_of)
  from stripe_customers c join lease_tenants x on x.tenant_id = c.tenant_id join leases l on l.id = x.lease_id and l.status = 'active'
  where c.autopay_enabled and c.autopay_payment_method is not null and lease_rent_due(l.id, p_as_of) > 0
    and not exists (select 1 from stripe_payments p where p.lease_id = l.id and p.status in ('created', 'processing'))
    and not exists (select 1 from payment_reports r where r.lease_id = l.id and r.status = 'pending' and payment_report_fresh(r, p_as_of))
  order by l.id, c.autopay_since;
$function$;


CREATE OR REPLACE FUNCTION public.resident_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ids uuid[] := array(select resident_me());
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'name', (select name from tenants where id = v_ids[1]),
    'settings', (select jsonb_object_agg(key, value) from portal_settings where key !~ '^(roca_|dues_|owner_pay_|plaid_|bank_|stripe_pmc|setup_|mfa_|automation_|court_days|writ_|sheriff_|lc_|pending_hold)' and key !~ '_alert_email$'),
    'leases', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'status', l.status, 'former', l.status = 'past', 'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'move_in_charges_posted', l.move_in_charges_posted, 'account_number', coalesce(l.account_number, upper(left(l.id::text, 8))), 'address', coalesce(u.address, p.street), 'unit_number', u.unit_number,
        'pay_to', (select jsonb_build_object('name', a.name, 'entity', a.entity, 'kind', a.kind, 'zelle_to', a.pay_zelle_to, 'zelle_name', a.pay_zelle_name, 'zelle_qr', a.pay_zelle_qr, 'stripe_account', a.stripe_account, 'bank_transfer', a.pay_bank_transfer, 'note', a.pay_note) from bank_accounts a where a.id = l.pay_to_account_id),
        'start_date', l.start_date, 'end_date', l.end_date, 'lease_type', l.lease_type, 'rent', l.rent, 'tenant_rent', lease_tenant_rent(l.id), 'deposit_held', l.deposit_held,
        'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
        'tenants', (select jsonb_agg(t.name order by t.name) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'account', e.gl_account, 'amount', e.amount) order by e.entry_date, e.id)
                    from lease_ledger_entries e where e.lease_id = l.id),
        'files', (select jsonb_agg(jsonb_build_object('kind', f.kind, 'status', f.status, 'dated', f.dated, 'note', f.note) order by f.dated) from lease_files f where f.lease_id = l.id)))
      from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
      where (l.status in ('active', 'future') or exists (select 1 from move_outs mo where mo.lease_id = l.id and mo.access_ends_at > now() and mo.access_removed_at is null))
        and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids))), '[]'::jsonb),
    'land_contracts', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'property', p.name, 'street', p.street, 'monthly_payment', c.monthly_payment, 'contract_date', c.contract_date,
        'maturity_date', c.maturity_date, 'interest_rate', c.interest_rate, 'purchase_price', c.purchase_price,
        'principal_now', (select s.ending_balance from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date order by s.n desc limit 1),
        'balance', (select coalesce(sum(amount), 0) from land_contract_ledger where contract_id = c.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'amount', e.amount) order by e.entry_date, e.id)
                    from land_contract_ledger e where e.contract_id = c.id)))
      from land_contracts c join rental_properties p on p.id = c.property_id
      where c.status = 'active' and exists (select 1 from land_contract_buyers b where b.contract_id = c.id and b.tenant_id = any(v_ids))), '[]'::jsonb),
    'signing', coalesce((select jsonb_agg(jsonb_build_object('doc_id', d.id, 'title', d.title, 'unit_label', d.unit_label, 'status', d.status,
        'created_at', d.created_at, 'executed_at', d.executed_at, 'executed_pdf_path', d.executed_pdf_path, 'you_signed', s.signed_at is not null) order by d.created_at desc)
      from lease_signing_docs d join lease_signing_signers s on s.doc_id = d.id
      where lower(s.email) = lower(auth.email()) and d.status <> 'void'), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'subject', r.subject, 'description', r.description,
        'status', r.status, 'created_at', r.created_at, 'photos', r.photos, 'entry_permission', r.entry_permission,
        'updates', (select jsonb_agg(jsonb_build_object('at', u2.at, 'status', u2.status, 'note', u2.note) order by u2.at)
                    from maintenance_request_updates u2 where u2.request_id = r.id and u2.visible_to_resident)) order by r.created_at desc)
      from maintenance_requests r where r.tenant_id = any(v_ids)), '[]'::jsonb),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('title', a.title, 'body', a.body, 'created_on', a.created_on) order by a.created_on desc)
      from announcements a where a.status = 'current' and (a.expires_on is null or a.expires_on >= current_date)), '[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('name', v.name, 'category', coalesce(v.resident_category, v.category), 'email', v.email,
        'phone', coalesce(v.phone, v.mobile)) order by v.name) from vendors v where v.show_to_residents), '[]'::jsonb)
  );
end;
$function$;
