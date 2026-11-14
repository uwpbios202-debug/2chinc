-- Bank page: a deposit in ROCA1's account that is an agency's payment for a caseworker's client (ACH, EFT or check, Stephen 10/22/2026).
-- Staff pick the client's lease; the payment posts to the tenant's rent account under the agency's name, flagged as received by ROCA1, so the
-- ROCA1 rent split applies (see 20261114010000). The security deposit part still lands on the deposit ledger first (payment_post).

create or replace function bank_staff_assign_caseworker(p_receipt uuid, p_lease uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bank_receipts; v_cw caseworkers; v_tenant uuid; v_report uuid; v_method text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into b from bank_receipts where id = p_receipt for update;
  if b.id is null then raise exception 'Deposit not found'; end if;
  if b.status in ('posted', 'stripe_payout', 'ignored') or b.matched_report_id is not null then raise exception 'That deposit is already handled.'; end if;
  if b.bank_account_id is distinct from bank_account_by_key('first_citizens_roca1') then
    raise exception 'A caseworker pays ROCA1 only. This deposit is not in ROCA1''s account.';
  end if;
  if b.amount <= 0 then raise exception 'That is not a deposit.'; end if;
  select c.* into v_cw from caseworkers c join caseworker_clients cc on cc.caseworker_id = c.id join lease_tenants lt on lt.tenant_id = cc.tenant_id
    where lt.lease_id = p_lease and c.active order by c.created_at limit 1;
  if v_cw.id is null then raise exception 'That lease has no caseworker on file. Add the caseworker first (Staff, Caseworkers).'; end if;
  select lt.tenant_id into v_tenant from lease_tenants lt where lt.lease_id = p_lease order by lt.tenant_id limit 1;
  v_method := bank_receipt_method(coalesce(b.description, '') || ' ' || coalesce(b.payer_name, ''));
  insert into payment_reports (tenant_id, lease_id, method, amount, paid_on, confirmation_code, note, caseworker_id, received_account_id, payer_name)
  values (v_tenant, p_lease, v_method, b.amount, b.posted_on, nullif(left(coalesce(b.reference, ''), 60), ''),
          'Paid by the agency (bank deposit)' || coalesce(' - ' || nullif(trim(coalesce(p_note, '')), ''), ''), v_cw.id, b.bank_account_id,
          coalesce(nullif(v_cw.agency, ''), 'Agency') || ' (' || v_cw.name || ')')
  returning id into v_report;
  perform payment_post(v_report, p_receipt, 'staff', lower(auth.email()));
  update bank_receipts set confidence = 'agency payment (assigned by staff)' where id = p_receipt;
  return jsonb_build_object('report', v_report, 'amount', b.amount);
end;
$$;
revoke all on function bank_staff_assign_caseworker(uuid, uuid, text) from public, anon;
grant execute on function bank_staff_assign_caseworker(uuid, uuid, text) to authenticated;

CREATE OR REPLACE FUNCTION public.bank_staff_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'institution', a.institution, 'mask', a.mask, 'bank_key', a.bank_key,
        'entity', a.entity, 'truth_source', a.truth_source,
        'connected', a.plaid_item_id is not null, 'last_synced_at', a.last_synced_at, 'last_error', a.last_error, 'active', a.active) order by a.kind desc, a.name) from bank_accounts a), '[]'::jsonb),
    'queue', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'description', b.description,
        'reason', b.review_reason, 'kind', bank_receipt_side(b.id), 'source', b.source,
        'candidates', coalesce((select jsonb_agg(jsonb_build_object('kind', c.target_kind, 'id', c.target_id, 'label', c.label, 'why', c.why) order by c.rank, c.label)
                                from (select * from bank_candidates(b.id) order by rank limit 5) c), '[]'::jsonb)) order by b.posted_on desc)
      from bank_receipts b where b.status = 'needs_review'), '[]'::jsonb),
    'agencies', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'agency', h.agency_name, 'unit', ru.unit_number, 'tenants', l.tenants_label,
        'portion', h.agency_portion, 'owes', (select coalesce(sum(amount), 0) from assistance_ledger x where x.assistance_id = h.id)) order by h.agency_name, ru.unit_number)
      from housing_assistance h join leases l on l.id = h.lease_id left join rental_units ru on ru.id = l.unit_id where h.status = 'active'), '[]'::jsonb),
    'caseworker_leases', coalesce((select jsonb_agg(jsonb_build_object('lease_id', l.id, 'unit', ru.unit_number, 'tenants', l.tenants_label, 'caseworker', c.name, 'agency', c.agency,
        'owes', (select coalesce(sum(e.amount), 0) from lease_ledger_entries e where e.lease_id = l.id)) order by ru.unit_number, c.name)
      from (select distinct cc.caseworker_id, lt.lease_id from caseworker_clients cc join lease_tenants lt on lt.tenant_id = cc.tenant_id) x
      join caseworkers c on c.id = x.caseworker_id and c.active join leases l on l.id = x.lease_id and l.status in ('active', 'future') left join rental_units ru on ru.id = l.unit_id), '[]'::jsonb),
    'confirmations', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'source', b.source,
        'kind', bank_receipt_side(b.id), 'linked', b.linked_receipt_id is not null, 'report', b.confirms_report_id) order by b.posted_on desc)
      from (select * from bank_receipts where role = 'confirmation' and posted_on > current_date - 45 order by posted_on desc limit 40) b), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'how', b.confidence, 'posted_at', b.posted_at,
        'source', b.source, 'status', b.status, 'kind', bank_receipt_side(b.id)) order by b.posted_at desc nulls last)
      from (select * from bank_receipts where status in ('posted', 'stripe_payout') order by posted_at desc nulls last limit 30) b), '[]'::jsonb));
end;
$function$;
