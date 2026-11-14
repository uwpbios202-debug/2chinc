-- Specific bank accounts tied to specific leases (Stephen, 10/9/2026).
--
-- Until now every tenant payment belonged in the 2nd Chance Chase account and every association payment in ROCA1's.
-- A lease can now name the account its rent goes to (leases.pay_to_account_id; empty = the default 2nd Chance Chase
-- account). Units 4, 5 and 14 go to Yawdcour's Chase account (new, added here); unit 16 goes to ROCA1's First Citizens
-- account, where ROCA1 takes the owner's association dues, assessments and fees and sends the balance to the owner (an
-- exception to the 10/5 tenants-versus-owners rule, confirmed by Stephen for unit 16 only).
--
-- What follows from the lease's account: the deposit matcher offers a lease only for deposits that landed in that
-- account; a deposit in any other account cannot be posted to it; the tenant's Payments page shows that account's
-- Zelle / transfer instructions and hides online bank payment (Stripe pays out to one bank only), PayPal and Cash App.

alter table bank_accounts add column if not exists pay_zelle_to text;
alter table bank_accounts add column if not exists pay_zelle_name text;
alter table bank_accounts add column if not exists pay_bank_transfer text;   -- shown to tenants who pay by bank transfer
alter table bank_accounts add column if not exists pay_note text;            -- one line shown above the payment options
alter table leases add column if not exists pay_to_account_id uuid references bank_accounts(id);

insert into bank_accounts (name, kind, institution, bank_key, entity, truth_source, active)
select 'Yawdcour - Chase', 'tenant', 'Chase', 'chase_yawdcour', 'Yawdcour', 'csv', true
 where not exists (select 1 from bank_accounts where bank_key = 'chase_yawdcour');

update leases l set pay_to_account_id = bank_account_by_key('chase_yawdcour')
  from rental_units u where u.id = l.unit_id and u.unit_number in ('4', '5', '14') and l.status in ('active', 'future') and l.pay_to_account_id is null;
update leases l set pay_to_account_id = bank_account_by_key('first_citizens_roca1')
  from rental_units u where u.id = l.unit_id and u.unit_number = '16' and l.status in ('active', 'future') and l.pay_to_account_id is null;

-- The account a lease's rent belongs in.
create or replace function lease_receiving_account(p_lease uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce((select pay_to_account_id from leases where id = p_lease), bank_account_by_key('chase_2ch'));
$$;
revoke all on function lease_receiving_account(uuid) from public, anon, authenticated;
grant execute on function lease_receiving_account(uuid) to service_role;
create or replace function payment_post(p_report uuid, p_receipt uuid, p_source text, p_by text)
returns void
language plpgsql security definer set search_path = public as $$
declare r payment_reports; b bank_receipts; v_entry bigint; v_entry2 bigint; v_label text; v_dep_out numeric := 0; v_dep_part numeric := 0; v_rent_part numeric;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null or r.status <> 'pending' then return; end if;
  if p_receipt is not null then
    select * into b from bank_receipts where id = p_receipt for update;
    if b.id is null then raise exception 'Deposit not found'; end if;
    if b.matched_report_id is not null and b.matched_report_id <> r.id then raise exception 'That deposit is already matched to another payment.'; end if;
    if b.status in ('posted', 'stripe_payout', 'ignored') then raise exception 'That deposit is already %.', replace(b.status, '_', ' '); end if;
    if r.lease_id is not null then
      -- A lease's rent belongs in the account its lease names (default: 2nd Chance Chase).
      if b.bank_account_id is distinct from lease_receiving_account(r.lease_id) then
        raise exception 'That deposit is in the % account; this lease pays into %.',
          (select name from bank_accounts where id = b.bank_account_id), (select name from bank_accounts where id = lease_receiving_account(r.lease_id));
      end if;
    elsif bank_receipt_side(b.id) <> payment_report_side(r) then
      raise exception 'That deposit is in the % account; this payment belongs to the % side (tenants pay 2nd Chance at Chase, owners pay ROCA1 at First Citizens).',
        case bank_receipt_side(b.id) when 'owner' then 'ROCA1 (First Citizens)' else '2nd Chance (Chase)' end, payment_report_side(r);
    end if;
  end if;
  v_label := initcap(replace(r.method, '_', ' ')) || ' payment';
  if r.condo_account_id is not null then
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, origin, entered_by, correction_note, payment_report_id)
    values (r.condo_account_id, 'Association Fee Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
            'Payment by ' || coalesce(r.payer_name, (select name from condo_owners where id = r.owner_id)), -r.amount, 'staff', coalesce(p_by, 'system'),
            'Reported online; verified via ' || p_source || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
    returning id into v_entry;
  elsif r.lease_id is not null then
    -- Move-in money pays the security deposit first, then rent. The deposit has its own ledger account, so the
    -- rent logic (late fees, reminders, autopay, notices) does not count deposit money as prepaid rent.
    if coalesce((select move_in_charges_posted from leases where id = r.lease_id), false) then
      select coalesce(sum(amount), 0) into v_dep_out from lease_ledger_entries where lease_id = r.lease_id and gl_account = 'Security Deposit Liability';
    end if;
    v_dep_part := least(r.amount, greatest(v_dep_out, 0));
    v_rent_part := r.amount - v_dep_part;
    if v_dep_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Security Deposit Liability', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)) || ' (security deposit)', -v_dep_part, 'payment_report',
              'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry;
    end if;
    if v_rent_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Rent Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)), -v_rent_part, 'payment_report',
              'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry2;
      v_entry := coalesce(v_entry2, v_entry);
    end if;
  elsif r.land_contract_id is not null then
    insert into land_contract_ledger (contract_id, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.land_contract_id, r.paid_on, 'payment', v_label || ' (verified)', 'Payment by ' || coalesce(r.payer_name, ''), -r.amount, 'payment_report',
            'Verified via ' || p_source)
    returning id into v_entry;
  end if;
  update payment_reports set status = 'verified', verified_at = now(), verified_by = p_by, verification_source = p_source,
         bank_receipt_id = p_receipt, ledger_entry_id = v_entry where id = r.id;
  if p_receipt is not null then
    -- A matched deposit is a posted deposit: it leaves the review queue and can never be posted again.
    update bank_receipts set matched_report_id = r.id, status = 'posted', posted_at = coalesce(posted_at, now()), review_reason = null where id = p_receipt;
    perform bank_link_confirmations(p_receipt);
  end if;
end;
$$;

create or replace function bank_post_receipt(p_receipt uuid, p_kind text, p_target uuid, p_how text, p_by text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare b bank_receipts; v_report uuid; v_tenant uuid; v_owner uuid; v_method text; v_lease uuid; v_contract uuid; v_acct uuid; v_side text;
begin
  select * into b from bank_receipts where id = p_receipt for update;
  if b.id is null then raise exception 'Deposit not found'; end if;
  if b.status in ('posted', 'stripe_payout') or b.matched_report_id is not null then raise exception 'That deposit is already posted.'; end if;
  v_side := bank_receipt_side(b.id);
  if p_kind = 'lease' and b.bank_account_id is distinct from lease_receiving_account(p_target) then
    raise exception 'That deposit is in the % account; this lease pays into %.',
      (select name from bank_accounts where id = b.bank_account_id), (select name from bank_accounts where id = lease_receiving_account(p_target));
  elsif p_kind <> 'lease' and (v_side = 'owner') <> (p_kind = 'condo') then
    raise exception 'That deposit is in the % account; it can only post to the % side.',
      case v_side when 'owner' then 'ROCA1 (First Citizens)' else '2nd Chance (Chase)' end, case v_side when 'owner' then 'owner dues' else 'tenant rent' end;
  end if;
  v_method := bank_receipt_method(coalesce(b.description, '') || ' ' || coalesce(b.payer_name, ''));
  if p_kind = 'lease' then
    v_lease := p_target;
    select lt.tenant_id into v_tenant from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = v_lease
      order by (select count(*) from unnest(payer_tokens(b.payer_name)) w where lower(t.name) like '%' || w || '%') desc, t.created_at limit 1;
  elsif p_kind = 'land_contract' then
    v_contract := p_target;
    select bu.tenant_id into v_tenant from land_contract_buyers bu where bu.contract_id = v_contract order by bu.tenant_id limit 1;
  elsif p_kind = 'condo' then
    v_acct := p_target;
    select s.owner_id into v_owner from condo_ledger_accounts a join condo_ownerships s on s.unit_id = a.unit_id and s.is_current where a.id = v_acct limit 1;
  else raise exception 'Unknown target'; end if;
  if v_tenant is null and v_owner is null then raise exception 'No payer found for that target'; end if;
  insert into payment_reports (tenant_id, owner_id, lease_id, land_contract_id, condo_account_id, method, amount, paid_on, confirmation_code, payer_name, note, status)
  values (v_tenant, v_owner, v_lease, v_contract, v_acct, v_method, b.amount, b.posted_on, nullif(left(coalesce(b.reference, ''), 40), ''), nullif(b.payer_name, ''),
          'Posted automatically from the bank deposit (' || p_how || ')', 'pending')
  returning id into v_report;
  perform payment_post(v_report, p_receipt, 'bank_feed', p_by);
  update bank_receipts set status = 'posted', confidence = p_how, posted_at = now(), review_reason = null, matched_report_id = v_report where id = p_receipt;
  return v_report;
end;
$$;

create or replace function payments_auto_match()
returns integer
language plpgsql security definer set search_path = public as $$
declare rec record; n int := 0; v_dup uuid;
begin
  for rec in
    with cand as (
      select b.id as receipt_id, r.id as report_id, b.source, b.role
      from bank_receipts b
      join bank_accounts ba on ba.id = b.bank_account_id
      join payment_reports r on r.status = 'pending' and r.amount = b.amount and abs(b.posted_on - r.paid_on) <= 4
      left join tenants t on t.id = r.tenant_id
      left join condo_owners o on o.id = r.owner_id
      left join leases l on l.id = r.lease_id
      left join condo_ledger_accounts ca on ca.id = r.condo_account_id
      left join condo_units cu on cu.id = ca.unit_id
      where b.matched_report_id is null and b.confirms_report_id is null and not b.ignored and b.amount > 0
        and b.status in ('new', 'needs_review', 'confirmation')
        and (case when r.lease_id is not null then ba.id = lease_receiving_account(r.lease_id) else ba.kind = payment_report_side(r) end)
        and (
          exists (select 1 from regexp_split_to_table(lower(coalesce(t.name, o.name, '')), '\s+') w where length(w) >= 3 and lower(coalesce(b.payer_name, '') || ' ' || coalesce(b.description, '')) like '%' || w || '%')
          or (l.legacy_lease_number is not null and coalesce(b.description, '') || coalesce(b.reference, '') like '%' || l.legacy_lease_number || '%')
          or (cu.pin is not null and coalesce(b.description, '') || coalesce(b.reference, '') like '%' || cu.pin || '%')
          or (r.confirmation_code is not null and length(r.confirmation_code) >= 5 and coalesce(b.description, '') || coalesce(b.reference, '') ilike '%' || r.confirmation_code || '%')
          or (r.payer_name is not null and length(r.payer_name) >= 3 and lower(coalesce(b.payer_name, '') || ' ' || coalesce(b.description, '')) like '%' || lower(r.payer_name) || '%')
        )
    )
    select c.* from cand c
    where (select count(*) from cand x where x.receipt_id = c.receipt_id) = 1
      and (select count(*) from cand x where x.report_id = c.report_id and x.role = c.role) = 1
  loop
    if rec.role = 'confirmation' then
      update bank_receipts set confirms_report_id = rec.report_id where id = rec.receipt_id;
      update payment_reports set bank_alert_seen_at = coalesce(bank_alert_seen_at, now()) where id = rec.report_id;
      continue;
    end if;
    v_dup := bank_receipt_duplicate_of(rec.receipt_id);
    if v_dup is not null then
      update bank_receipts set status = 'needs_review', review_reason = 'Possible duplicate of a deposit already posted (' ||
        (select to_char(posted_on, 'FMMM/FMDD') || ' ' || coalesce(payer_name, '') from bank_receipts where id = v_dup) || ')' where id = rec.receipt_id;
      continue;
    end if;
    perform payment_post(rec.report_id, rec.receipt_id, case rec.source when 'chase_csv' then 'bank_csv' when 'plaid' then 'bank_feed' when 'manual' then 'staff' else 'staff' end, 'system');
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function bank_candidates(p_receipt uuid)
returns table (target_kind text, target_id uuid, label text, why text, rank int)
language plpgsql stable security definer set search_path = public
as $$
declare b bank_receipts; v_scope text; v_text text; v_tokens text[]; v_norm text;
begin
  select * into b from bank_receipts where id = p_receipt;
  if b.id is null then return; end if;
  v_scope := coalesce((select kind from bank_accounts where id = b.bank_account_id), 'tenant');
  v_text := coalesce(b.description, '') || ' ' || coalesce(b.reference, '') || ' ' || coalesce(b.payer_name, '');
  v_norm := payer_norm(coalesce(nullif(b.payer_name, ''), b.description));
  v_tokens := payer_tokens(coalesce(nullif(b.payer_name, ''), b.description));

  if v_scope = 'tenant' or exists (select 1 from leases x where x.pay_to_account_id = b.bank_account_id and x.status in ('active', 'future')) then
    return query
    with active as (
      select l.id, l.legacy_lease_number num, l.tenants_label, coalesce(ru.unit_number, '') unit, l.rent
      from leases l left join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')
        and lease_receiving_account(l.id) = b.bank_account_id),
    by_acct as (
      select a.id, 'lease'::text k, 1 r, 'account number ' || a.num || ' in the memo' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from active a where a.num is not null and length(a.num) >= 5 and v_text ~ ('(^|[^0-9])0*' || ltrim(a.num, '0') || '([^0-9]|$)')),
    by_alias as (
      select al.lease_id id, 'lease'::text k, 2 r, 'known payer' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from payer_aliases al join active a on a.id = al.lease_id where al.scope = 'tenant' and al.alias = v_norm and v_norm <> ''),
    by_name as (
      select a.id, 'lease'::text k, 3 r, 'payer name matches the tenant' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from active a
      where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(a.tenants_label)) x where x = t))
      union
      select a.id, 'lease'::text, 3, 'payer name matches a tenant on the lease', a.tenants_label || ' (unit ' || a.unit || ')'
      from active a join lease_tenants lt on lt.lease_id = a.id join tenants t2 on t2.id = lt.tenant_id
      where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(t2.name)) x where x = t))),
    by_contract as (
      select c.id, 'land_contract'::text k, 3 r, 'payer name matches the buyer' w, c.buyers_label lab
      from land_contracts c where c.status = 'active' and b.bank_account_id = bank_account_by_key('chase_2ch') and cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(c.buyers_label)) x where x = t))
      union
      select al.land_contract_id, 'land_contract', 2, 'known payer', c.buyers_label
      from payer_aliases al join land_contracts c on c.id = al.land_contract_id where al.scope = 'tenant' and al.alias = v_norm and v_norm <> '' and c.status = 'active' and b.bank_account_id = bank_account_by_key('chase_2ch'))
    select d.k, d.id, d.lab, d.w, d.r from (
      select distinct on (x.k, x.id) x.k, x.id, x.lab, x.w, x.r from (
        select * from by_acct union all select * from by_alias union all select * from by_name union all select * from by_contract) x
      order by x.k, x.id, x.r) d
    order by d.r, d.lab;
  end if;
  if v_scope <> 'tenant' then
    return query
    with cur as (
      select a.id acct, u.unit_number, u.pin, o.name owner_name, o.id owner_id
      from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current join condo_owners o on o.id = s.owner_id
      join condo_ledger_accounts a on a.unit_id = u.id and a.billing_account and not a.excluded),
    by_acct as (
      select c.acct id, 'condo'::text k, 1 r, case when c.pin is not null and v_text like '%' || c.pin || '%' then 'tax key ' || c.pin || ' in the memo' else 'unit ' || c.unit_number || ' in the memo' end w,
             'Unit ' || c.unit_number || ' (' || c.owner_name || ')' lab
      from cur c where (c.pin is not null and length(c.pin) >= 6 and v_text like '%' || c.pin || '%')
        or v_text ~* ('(unit|apt|#)\s*' || c.unit_number || '([^0-9]|$)')),
    by_alias as (
      select al.condo_account_id, 'condo'::text, 2, 'known payer', 'Unit ' || c.unit_number || ' (' || c.owner_name || ')'
      from payer_aliases al join cur c on c.acct = al.condo_account_id where al.scope = 'owner' and al.alias = v_norm and v_norm <> ''),
    by_name as (
      select c.acct, 'condo'::text, 3, 'payer name matches the owner', 'Unit ' || c.unit_number || ' (' || c.owner_name || ')'
      from cur c where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(c.owner_name)) x where x = t)))
    select d.k, d.id, d.lab, d.w, d.r from (
      select distinct on (x.k, x.id) x.k, x.id, x.lab, x.w, x.r from (
        select * from by_acct union all select * from by_alias union all select * from by_name) x
      order by x.k, x.id, x.r) d
    order by d.r, d.lab;
  end if;
end;
$$;

create or replace function resident_home()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me());
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'name', (select name from tenants where id = v_ids[1]),
    'settings', (select jsonb_object_agg(key, value) from portal_settings),
    'leases', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'status', l.status, 'former', l.status = 'past', 'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'move_in_charges_posted', l.move_in_charges_posted, 'account_number', coalesce(l.legacy_lease_number, upper(left(l.id::text, 8))), 'address', coalesce(u.address, p.street), 'unit_number', u.unit_number,
        'pay_to', (select jsonb_build_object('name', a.name, 'entity', a.entity, 'kind', a.kind, 'zelle_to', a.pay_zelle_to, 'zelle_name', a.pay_zelle_name, 'bank_transfer', a.pay_bank_transfer, 'note', a.pay_note) from bank_accounts a where a.id = l.pay_to_account_id),
        'start_date', l.start_date, 'end_date', l.end_date, 'lease_type', l.lease_type, 'rent', l.rent, 'deposit_held', l.deposit_held,
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
$$;
