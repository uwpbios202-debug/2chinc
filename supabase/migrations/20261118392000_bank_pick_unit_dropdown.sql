-- Bank page: Pick a unit is a dropdown on every waiting deposit. Leases are listed only for the bank account the deposit landed in
-- (bank_post_receipt refuses any other), so the overview now returns each receipt's bank account and each lease's receiving account. (Stephen, 11/8/2026.)
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
        'reason', b.review_reason, 'kind', bank_receipt_side(b.id), 'source', b.source, 'bank_account_id', b.bank_account_id,
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
    'pick_condo', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'unit', u.unit_number, 'label', 'Unit ' || u.unit_number || ' (' || o.name || ')')
        order by case when u.unit_number ~ '^[0-9]+$' then u.unit_number::int end, u.unit_number)
      from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current join condo_owners o on o.id = s.owner_id
      join condo_ledger_accounts a on a.unit_id = u.id and a.billing_account and not a.excluded), '[]'::jsonb),
    'pick_lease', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'account', lease_receiving_account(l.id), 'unit', ru.unit_number, 'label', l.tenants_label || ' (unit ' || coalesce(ru.unit_number, '?') || ')')
        order by ru.unit_number, l.tenants_label)
      from leases l left join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')), '[]'::jsonb),
    'confirmations', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'source', b.source,
        'kind', bank_receipt_side(b.id), 'linked', b.linked_receipt_id is not null, 'report', b.confirms_report_id) order by b.posted_on desc)
      from (select * from bank_receipts where role = 'confirmation' and posted_on > current_date - 45 order by posted_on desc limit 40) b), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'how', b.confidence, 'posted_at', b.posted_at,
        'source', b.source, 'status', b.status, 'kind', bank_receipt_side(b.id)) order by b.posted_at desc nulls last)
      from (select * from bank_receipts where status in ('posted', 'stripe_payout') order by posted_at desc nulls last limit 30) b), '[]'::jsonb));
end;
$function$;
revoke all on function bank_staff_overview() from public, anon;
grant execute on function bank_staff_overview() to authenticated;
