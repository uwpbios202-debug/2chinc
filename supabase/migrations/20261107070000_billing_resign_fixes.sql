-- Billing and re-signing fixes from the 10/9/2026 code review of applicant -> move-in -> second rent.
--
-- 1. Deposit money counted as prepaid rent. Every lease payment was posted to 'Rent Income', but the move-in
--    deposit charge lives in 'Security Deposit Liability', so after a $2,725 move-in payment (deposit $1,800 + rent
--    $925) the rent logic showed the next two months as paid: no reminder, late fee, autopay or notice for month two.
--    payment_post now pays the deposit first (new leases only), then rent, as two ledger lines; the reversal
--    follows the same split.
-- 2. Re-signing created a second lease. lease_from_signing now re-signs onto an existing active or future lease
--    on the same unit that shares a person (name or email) with the signers: no new lease, deposit charge,
--    first-month charge or welcome letter.
-- 3. People who share an email address were merged. Tenants are now matched on name AND email.
-- 5. A lease starting on the 29th-31st skipped next month's prorated bill in a short month. Now at least one day.

alter table lease_ledger_entries add column if not exists payment_report_id uuid;
create index if not exists lease_ledger_entries_payment_report_idx on lease_ledger_entries (payment_report_id) where payment_report_id is not null;

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
    if bank_receipt_side(b.id) <> payment_report_side(r) then
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

create or replace function lease_payment_reverse(p_report uuid, p_amount numeric, p_reason text, p_by text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r payment_reports; v_amt numeric; v_entry bigint; v_orig bigint; v_rp numeric; v_dp numeric; v_rr numeric; v_dr numeric; v_rent_rev numeric; v_dep_rev numeric;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null then raise exception 'Payment not found'; end if;
  if r.status not in ('verified', 'reversed') then raise exception 'Only a posted payment can be reversed.'; end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the payment is reversed (bounced, refunded, disputed…).'; end if;
  v_amt := round(coalesce(p_amount, r.amount - r.reversed_amount), 2);
  if v_amt <= 0 or v_amt > r.amount - r.reversed_amount then raise exception 'Up to % can still be reversed.', to_char(r.amount - r.reversed_amount, 'FM$999,990.00'); end if;
  if r.condo_account_id is not null then
    select id into v_orig from condo_ledger_entries where payment_report_id = r.id and kind = 'payment' order by id limit 1;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note, reverses_entry_id, payment_report_id)
    values (r.condo_account_id, 'Association Fee Income', current_date, 'reversal', 'Payment reversed', r.method,
            'Payment reversed: ' || trim(p_reason), v_amt, 'staff', p_by, 'Reverses the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept.', v_orig, r.id)
    returning id into v_entry;
  elsif r.lease_id is not null then
    -- A payment posted since deposits were split has a rent line and maybe a deposit line; reverse rent first, then deposit.
    -- Older payments have no linked lines and reverse entirely against rent, as before.
    select coalesce(-sum(amount) filter (where kind = 'payment' and gl_account = 'Rent Income'), 0),
           coalesce(-sum(amount) filter (where kind = 'payment' and gl_account = 'Security Deposit Liability'), 0),
           coalesce(sum(amount) filter (where kind = 'reversal' and gl_account = 'Rent Income'), 0),
           coalesce(sum(amount) filter (where kind = 'reversal' and gl_account = 'Security Deposit Liability'), 0)
      into v_rp, v_dp, v_rr, v_dr from lease_ledger_entries where payment_report_id = r.id;
    if v_rp + v_dp = 0 then
      v_rent_rev := v_amt; v_dep_rev := 0;
    else
      v_rent_rev := least(v_amt, greatest(v_rp - v_rr, 0)); v_dep_rev := v_amt - v_rent_rev;
    end if;
    if v_rent_rev > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Rent Income', current_date, 'reversal', 'Payment reversed', r.method, 'Payment reversed: ' || trim(p_reason), v_rent_rev, 'payment_reversal',
              'Reverses the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment (ledger line ' || coalesce(r.ledger_entry_id::text, '?') || '); original line kept. By ' || coalesce(p_by, 'system') || '.', r.id)
      returning id into v_entry;
    end if;
    if v_dep_rev > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Security Deposit Liability', current_date, 'reversal', 'Payment reversed', r.method, 'Payment reversed: ' || trim(p_reason) || ' (security deposit)', v_dep_rev, 'payment_reversal',
              'Reverses the deposit part of the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept. By ' || coalesce(p_by, 'system') || '.', r.id)
      returning id into v_entry;
    end if;
  elsif r.land_contract_id is not null then
    insert into land_contract_ledger (contract_id, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.land_contract_id, current_date, 'reversal', 'Payment reversed', 'Payment reversed: ' || trim(p_reason), v_amt, 'payment_reversal',
            'Reverses the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept.')
    returning id into v_entry;
  end if;
  update payment_reports set reversed_amount = reversed_amount + v_amt, reversed_at = now(), reversed_reason = trim(p_reason), reversed_by = p_by,
         status = case when reversed_amount + v_amt >= amount then 'reversed' else status end
   where id = r.id;
  return jsonb_build_object('reversed', v_amt, 'entry', v_entry);
end;
$$;

create or replace function billing_post_month(p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare m date := date_trunc('month', p_month)::date; n_rent int := 0; n_credit int := 0; n_lc int := 0; r record;
  v_amt numeric; v_desc text; v_dim int; v_days int;
begin
  for r in select l.id, l.rent, l.start_date, l.move_in_charges_posted from leases l
           where l.status = 'active' and coalesce(l.rent, 0) > 0 and coalesce(l.start_date, m) <= m + 27
             and (l.end_date is null or l.end_date >= m)
             and not exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge'
                             and e.gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', e.entry_date) = m)
  loop
    -- Move-in rule (tenant-journey-spec): a full month's rent is paid to move in,
    -- covering the start date through the same day next month; the following
    -- month is billed only for the days left after that.
    v_amt := r.rent; v_desc := 'Rent';
    if r.move_in_charges_posted and extract(day from r.start_date) > 1
       and m = (date_trunc('month', r.start_date) + interval '1 month')::date then
      v_dim := extract(day from (m + interval '1 month' - interval '1 day'))::int;
      v_days := greatest(v_dim - least(extract(day from r.start_date)::int - 1, v_dim), 1);  -- at least one day, so a short month is never skipped
      v_amt := round(r.rent * v_days / v_dim, 2);
      v_desc := 'Rent (prorated ' || to_char(m + (v_dim - v_days), 'FMMM/FMDD') || '–' || to_char(m + v_dim - 1, 'FMMM/FMDD') || ', ' || v_days || ' of ' || v_dim || ' days)';
    end if;
    if v_amt > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
      values (r.id, 'Rent Income', m, 'charge', 'Charge', v_desc, v_amt, 'billing');
      n_rent := n_rent + 1;
    end if;
  end loop;
  -- Work in lieu of rent: monthly in-kind credit for ACTIVE agreements.
  for r in select w.id, w.lease_id, w.monthly_credit, w.title from work_agreements w join leases l on l.id = w.lease_id
           where w.status = 'active' and coalesce(w.monthly_credit, 0) > 0 and l.status = 'active'
             and (w.start_date is null or w.start_date <= m) and (w.end_date is null or w.end_date >= m)
             and not exists (select 1 from lease_ledger_entries e where e.lease_id = w.lease_id and e.kind = 'in_kind'
                             and e.source = 'billing' and date_trunc('month', e.entry_date) = m)
  loop
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.lease_id, 'Rent Income', m, 'in_kind', 'Work in lieu of rent', r.title, -r.monthly_credit, 'billing',
            'Monthly in-kind credit under the work agreement; credited for the previous month''s work.');
    insert into work_logs (lease_id, agreement_id, work_date, description, value, ledger_entry_id)
    values (r.lease_id, r.id, m, 'Monthly credit: ' || r.title, r.monthly_credit, currval(pg_get_serial_sequence('lease_ledger_entries', 'id')));
    n_credit := n_credit + 1;
  end loop;
  -- Land contract installments.
  for r in select c.id, c.monthly_payment from land_contracts c
           where c.status = 'active' and coalesce(c.monthly_payment, 0) > 0 and (c.first_payment_date is null or c.first_payment_date <= m)
             and not exists (select 1 from land_contract_ledger e where e.contract_id = c.id and e.kind = 'installment_due' and date_trunc('month', e.entry_date) = m)
  loop
    insert into land_contract_ledger (contract_id, entry_date, kind, legacy_gl, raw_type, description, amount, source)
    values (r.id, m, 'installment_due', 'Rent Income', 'Charge', 'Installment', r.monthly_payment, 'billing');
    n_lc := n_lc + 1;
  end loop;
  return jsonb_build_object('month', m, 'rent_charges', n_rent, 'work_credits', n_credit, 'land_contract_installments', n_lc);
end;
$$;

create or replace function lease_from_signing(p_doc uuid)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare
  d lease_signing_docs; v_lease uuid; v_unit uuid; v_unitnum text; v_rent numeric; v_dep numeric; v_start date; v_end date; v_type text;
  s record; v_tid uuid; v_names text; v_old uuid;
begin
  select id into v_lease from leases where signing_doc_id = p_doc;
  if v_lease is not null then return v_lease; end if;
  select * into d from lease_signing_docs where id = p_doc and status = 'signed';
  if d.id is null then raise exception 'Lease is not fully signed'; end if;
  v_unitnum := substring(coalesce(d.lease_data->>'unitSelect', d.unit_label) from '#\s*(\d+)');
  select u.id into v_unit from rental_units u join rental_properties p on p.id = u.property_id where p.key = 'roca1' and u.unit_number = v_unitnum;
  if v_unit is null then raise exception 'Unit not recognised from "%"', d.unit_label; end if;
  v_rent := nullif(regexp_replace(coalesce(d.lease_data->>'rentAmount', ''), '[^0-9.]', '', 'g'), '')::numeric;
  v_dep := nullif(regexp_replace(coalesce(d.lease_data->>'securityDeposit', ''), '[^0-9.]', '', 'g'), '')::numeric;
  v_start := coalesce(nullif(d.lease_data->>'initialStartDate', '')::date, current_date);
  v_end := nullif(d.lease_data->>'expirationDate', '')::date;
  v_type := case when d.lease_data->>'leaseType' = 'annual' then 'fixed' else 'at_will' end;
  select string_agg(name, ', ' order by position) into v_names from lease_signing_signers where doc_id = d.id;
  -- A tenant who already has a lease on this unit (active or future) re-signs onto it: no second lease, no second deposit or first-month charge.
  select l.id into v_old from leases l
   where l.unit_id = v_unit and l.status in ('active', 'future') and l.signing_doc_id is distinct from d.id
     and exists (select 1 from lease_tenants lt join tenants t on t.id = lt.tenant_id join lease_signing_signers sg on sg.doc_id = d.id
                  where lt.lease_id = l.id and (lower(t.name) = lower(sg.name) or lower(t.email) = lower(sg.email)))
   order by l.start_date desc limit 1;
  if v_old is not null then
    v_lease := v_old;
    update leases set signing_doc_id = d.id, application_id = coalesce(application_id, d.application_id), rent = coalesce(v_rent, rent),
           lease_type = v_type, end_date = case when v_type = 'fixed' then coalesce(v_end, end_date) end, tenants_label = v_names,
           correction_note = trim(coalesce(correction_note || ' ', '') || 'Re-signed on 2ndchinc.org (document ' || upper(left(d.id::text, 8)) || '); no new move-in charges.')
     where id = v_lease;
  else
  insert into leases (unit_id, legacy_rental, tenants_label, start_date, end_date, lease_type, status, rent, rent_start, legacy_balance, deposit_held,
                      signing_doc_id, application_id, correction_note)
  values (v_unit, '2ndchinc.org lease', v_names, v_start, case when v_type = 'fixed' then v_end end, v_type,
          case when v_start > current_date then 'future' else 'active' end, v_rent, v_start, 0, 0, d.id, d.application_id,
          'Created from the lease signed online (document ' || upper(left(d.id::text, 8)) || ').')
  returning id into v_lease;
  end if;
  for s in select * from lease_signing_signers where doc_id = d.id order by position loop
    -- Match on name AND email: two people may share one email (a parent and an adult child) and must stay two people.
    select id into v_tid from tenants where lower(email) = lower(s.email) and lower(name) = lower(s.name) limit 1;
    if v_tid is null then
      insert into tenants (name, email, phone) values (s.name, lower(s.email), s.phone) returning id into v_tid;
    else
      update tenants set phone = coalesce(phone, s.phone) where id = v_tid;
    end if;
    insert into lease_tenants (lease_id, tenant_id) values (v_lease, v_tid) on conflict do nothing;
  end loop;
  if v_old is null and coalesce(v_dep, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (v_lease, 'Security Deposit Liability', current_date, 'charge', 'Charge', 'Security deposit', v_dep, 'move_in');
  end if;
  if v_old is null and coalesce(v_rent, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (v_lease, 'Rent Income', v_start, 'charge', 'Charge', 'Rent (first month)', v_rent, 'move_in');
  end if;
  if v_old is null then update leases set move_in_charges_posted = true where id = v_lease; end if;
  insert into lease_files (lease_id, kind, status, file_path, dated, note)
  values (v_lease, 'signed_lease', 'on_file', 'lease-signing:' || d.executed_pdf_path, current_date, 'Signed online; executed copy in the system.');
  if v_old is null then update condo_units set occupancy = 'tenant' where id = (select condo_unit_id from rental_units where id = v_unit); end if;
  if v_old is null then perform letter_queue_to_tenants('2c-welcome', v_lease, 'welcome'); end if;
  return v_lease;
end;
$$;
