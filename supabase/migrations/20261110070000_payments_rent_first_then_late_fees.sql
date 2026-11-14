-- Payments are applied to RENT first, then to open late fees (Stephen, 10/11/2026: Milwaukee County best practice).
-- Before: every payment went to Rent Income, so a tenant who paid "the balance" left the late fee open and put the rent account into credit.
-- Now only money beyond the rent owed pays the late fee (its own ledger line on Late Fee Income); leftover stays as rent credit.
-- A reversal takes the late-fee part off first, then rent, then the security deposit. Late fees are still never part of lease_rent_due or a notice.

CREATE OR REPLACE FUNCTION public.payment_post(p_report uuid, p_receipt uuid, p_source text, p_by text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r payment_reports; b bank_receipts; v_entry bigint; v_entry2 bigint; v_label text; v_dep_out numeric := 0; v_dep_part numeric := 0; v_rent_part numeric; v_rent_out numeric; v_fee_out numeric; v_fee_part numeric := 0; v_entry3 bigint;
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
    -- Rent first, then late fees (Milwaukee County practice, Stephen 10/11/2026): only money beyond the rent owed pays open late fees;
    -- anything left over stays as rent credit.
    v_rent_out := lease_rent_due(r.lease_id, current_date);
    select greatest(coalesce(sum(amount), 0), 0) into v_fee_out from lease_ledger_entries where lease_id = r.lease_id and gl_account = 'Late Fee Income';
    v_fee_part := least(greatest(v_rent_part - v_rent_out, 0), v_fee_out);
    v_rent_part := v_rent_part - v_fee_part;
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
    if v_fee_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Late Fee Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)) || ' (late fee)', -v_fee_part, 'payment_report',
              'Rent is paid first; this part of the payment covered the late fee. Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry3;
      v_entry := coalesce(v_entry2, v_entry3, v_entry);
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
$function$;

CREATE OR REPLACE FUNCTION public.lease_payment_reverse(p_report uuid, p_amount numeric, p_reason text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r payment_reports; v_amt numeric; v_entry bigint; v_orig bigint; v_rp numeric; v_dp numeric; v_rr numeric; v_dr numeric; v_rent_rev numeric; v_dep_rev numeric; v_fp numeric; v_fr numeric; v_fee_rev numeric := 0;
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
           coalesce(sum(amount) filter (where kind = 'reversal' and gl_account = 'Security Deposit Liability'), 0),
           coalesce(-sum(amount) filter (where kind = 'payment' and gl_account = 'Late Fee Income'), 0),
           coalesce(sum(amount) filter (where kind = 'reversal' and gl_account = 'Late Fee Income'), 0)
      into v_rp, v_dp, v_rr, v_dr, v_fp, v_fr from lease_ledger_entries where payment_report_id = r.id;
    if v_rp + v_dp + v_fp = 0 then
      v_rent_rev := v_amt; v_dep_rev := 0;
    else
      -- The late-fee part was applied last, so it comes off first, then rent, then the deposit.
      v_fee_rev := least(v_amt, greatest(v_fp - v_fr, 0));
      v_rent_rev := least(v_amt - v_fee_rev, greatest(v_rp - v_rr, 0)); v_dep_rev := v_amt - v_fee_rev - v_rent_rev;
    end if;
    if v_fee_rev > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Late Fee Income', current_date, 'reversal', 'Payment reversed', r.method, 'Payment reversed: ' || trim(p_reason) || ' (late fee)', v_fee_rev, 'payment_reversal',
              'Reverses the late-fee part of the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept. By ' || coalesce(p_by, 'system') || '.', r.id)
      returning id into v_entry;
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
  if r.lease_id is not null and r.ledger_entry_id is not null then perform roca_rent_split_reverse(r.lease_id, r.ledger_entry_id, v_rent_rev, p_reason); end if;
  update payment_reports set reversed_amount = reversed_amount + v_amt, reversed_at = now(), reversed_reason = trim(p_reason), reversed_by = p_by,
         status = case when reversed_amount + v_amt >= amount then 'reversed' else status end
   where id = r.id;
  return jsonb_build_object('reversed', v_amt, 'entry', v_entry);
end;
$function$;
