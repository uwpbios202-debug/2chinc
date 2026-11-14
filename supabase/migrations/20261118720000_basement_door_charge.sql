-- Basement door rule (Stephen, 11/10/2026): FOR NOW ONLY THE 6626 BUILDING (Units 1-8; setting basement_door_units).
-- Anyone who leaves the basement front door unlocked is charged $215 per occurrence,
-- no limit. Guide: https://2ndchinc.org/documents/basement-door/ (inside: tiny square lock button only, never the knob;
-- outside: keypad lock key, then pull to check).
--
-- Tenants: a lease charge "Door Lock Charge", due from the date of the charge. Payments still go to RENT FIRST (Stephen chose
-- this 11/10/2026 to keep the Milwaukee County rent-first rule): only money beyond the rent owed pays open door charges, then
-- open late fees; leftover stays as rent credit. The charge is never rent (lease_rent_due counts Rent Income only), so it is
-- never part of a pay-or-vacate notice; an unpaid charge is enforced with a lease-violation notice (breach type below).
-- Reversals take the late-fee part off first, then the door part, then rent, then the deposit (reverse of the order applied).
-- Rent split on ROCA1-routed leases is unchanged: the door part is not the owner's rent and is not split.
--
-- Owners (Unit 6, owner-direct; owner-occupied Units 1 and 7): a ROCA1 fine on the owner's association account with the
-- usual Rules §10 notice and 14 days to ask for a hearing; ROCA1 Rules §11 already applies payments to fines before dues.
-- The $215 amount is to be adopted by a ROCA1 board resolution.

insert into portal_settings (key, value) values ('basement_door_charge', '215'), ('basement_door_units', '1,2,3,4,5,6,7,8') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Owners: ROCA1 fine schedule
insert into roca_fine_schedule (code, section, title, amount, basis, immediate, amount_note, charged_to)
values ('basement_door_unlocked', 'Basement door rule (11/10/2026), 6626 building', 'Basement door left unlocked', 215.00, 'occurrence', false,
        '$215 per occurrence, no limit; 6626 building only for now (Units 1-8); paid before association dues (Rules §11)', 'owner')
on conflict (code) do update set section = excluded.section, title = excluded.title, amount = excluded.amount, basis = excluded.basis,
  amount_note = excluded.amount_note, charged_to = excluded.charged_to, active = true;

-- ---------------------------------------------------------------------------
-- Tenants: lease-violation notice type (for an unpaid charge or repeated occurrences)
insert into lease_breach_types (code, category, title, provision_ref, lease_quote, remedy, consequence, prompt, sort) values
  ('basement_door', 'Rules', 'Basement door left unlocked', 'Basement Door Rule (https://2ndchinc.org/documents/basement-door/)',
   'The basement front door at 6626 N Bourbon St must be locked every time you leave the basement: press the small square lock button on the inside panel (never the turning knob), push the door shut, press the lock key on the keypad and pull on the door to check that it is locked. Leaving the door unlocked is charged $215 per occurrence, due from the date of the charge.',
   'Lock the basement front door every time you leave the basement, and pay the open door charge(s).',
   'An unlocked basement door puts every resident at risk. Each occurrence is charged $215. Not following the building rules or not paying the charge is a breach of the rental agreement and can lead to termination of the tenancy and eviction.',
   'Which door, the date and time it was found unlocked, who found it, and how you know who left it unlocked (camera, witness).', 200)
on conflict (code) do update set category = excluded.category, title = excluded.title, provision_ref = excluded.provision_ref,
  lease_quote = excluded.lease_quote, remedy = excluded.remedy, consequence = excluded.consequence, prompt = excluded.prompt, sort = excluded.sort;

-- ---------------------------------------------------------------------------
-- Staff "Add a charge" on a lease: new type door_unlocked
create or replace function lease_staff_post_charge(p_lease uuid, p_type text, p_amount numeric, p_date date, p_description text default null, p_note text default null)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare v_id bigint; v_gl text; v_label text; v_amt numeric := round(p_amount, 2);
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from leases where id = p_lease) then raise exception 'Lease not found'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if p_date is null or p_date > current_date + 31 or p_date < current_date - 366 then raise exception 'Enter a date within the past year (or up to a month ahead)'; end if;
  case p_type
    when 'rent'     then v_gl := 'Rent Income';                v_label := 'Rent';
    when 'late_fee' then v_gl := 'Late Fee Income';            v_label := 'Late fee';
    when 'deposit'  then v_gl := 'Security Deposit Liability'; v_label := 'Security deposit';
    when 'repairs'  then v_gl := 'Repairs Income';             v_label := 'Repairs / damage';
    when 'cleaning' then v_gl := 'Cleaning and Maint Income';  v_label := 'Cleaning';
    when 'door_unlocked' then v_gl := 'Door Lock Charge';      v_label := 'Basement door left unlocked';
    when 'other'    then v_gl := 'Other Income';               v_label := 'Other charge';
    else raise exception 'Choose the type of charge';
  end case;
  if p_type = 'other' and coalesce(trim(p_description), '') = '' then raise exception 'Describe the charge'; end if;
  if p_type = 'door_unlocked' and not exists (
       select 1 from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
        where l.id = p_lease and cu.unit_number = any (string_to_array(replace(coalesce(condo_setting('basement_door_units'), ''), ' ', ''), ','))) then
    raise exception 'The basement door charge applies only to the 6626 building (Units %) for now', coalesce(condo_setting('basement_door_units'), 'none');
  end if;
  if p_type = 'door_unlocked' and coalesce(trim(p_note), '') = '' then raise exception 'Say when the door was found unlocked and how you know who left it'; end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (p_lease, v_gl, p_date, 'charge', 'Charge', coalesce(nullif(trim(coalesce(p_description, '')), ''), v_label), v_amt, 'staff',
          'Entered by ' || auth.email() || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function lease_staff_post_charge(uuid, text, numeric, date, text, text) from public, anon;
grant execute on function lease_staff_post_charge(uuid, text, numeric, date, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- payment_post: rent first, then door charges, then late fees (from 20261114010000; only the lease branch changes)
CREATE OR REPLACE FUNCTION public.payment_post(p_report uuid, p_receipt uuid, p_source text, p_by text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r payment_reports; b bank_receipts; v_entry bigint; v_entry2 bigint; v_label text; v_dep_out numeric := 0; v_dep_part numeric := 0; v_rent_part numeric; v_rent_out numeric; v_fee_out numeric; v_fee_part numeric := 0; v_entry3 bigint;
        v_door_out numeric; v_door_part numeric := 0; v_entry4 bigint;
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
      if b.bank_account_id is distinct from coalesce(r.received_account_id, lease_receiving_account(r.lease_id)) then
        raise exception 'That deposit is in the % account; this lease pays into %.',
          (select name from bank_accounts where id = b.bank_account_id), (select name from bank_accounts where id = coalesce(r.received_account_id, lease_receiving_account(r.lease_id)));
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
    -- Rent first (Milwaukee County practice, Stephen 10/11/2026), then open basement door charges (Stephen 11/10/2026), then
    -- late fees: only money beyond the rent owed pays the other two; anything left over stays as rent credit.
    v_rent_out := lease_rent_due(r.lease_id, current_date);
    select greatest(coalesce(sum(amount), 0), 0) into v_door_out from lease_ledger_entries where lease_id = r.lease_id and gl_account = 'Door Lock Charge';
    v_door_part := least(greatest(v_rent_part - v_rent_out, 0), v_door_out);
    select greatest(coalesce(sum(amount), 0), 0) into v_fee_out from lease_ledger_entries where lease_id = r.lease_id and gl_account = 'Late Fee Income';
    v_fee_part := least(greatest(v_rent_part - v_rent_out - v_door_part, 0), v_fee_out);
    v_rent_part := v_rent_part - v_door_part - v_fee_part;
    if v_dep_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Security Deposit Liability', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)) || ' (security deposit)', -v_dep_part, 'payment_report',
              'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry;
    end if;
    if v_door_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Door Lock Charge', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)) || ' (basement door charge)', -v_door_part, 'payment_report',
              'Rent is paid first; this part of the payment covered the basement door charge. Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry4;
    end if;
    if v_fee_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Late Fee Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)) || ' (late fee)', -v_fee_part, 'payment_report',
              'Rent is paid first; this part of the payment covered the late fee. Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry3;
    end if;
    if v_rent_part > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Rent Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
              'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)), -v_rent_part, 'payment_report',
              'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
      returning id into v_entry2;
      v_entry := coalesce(v_entry2, v_entry);
    end if;
    v_entry := coalesce(v_entry2, v_entry3, v_entry4, v_entry);
    -- A payment that is only late fee has no rent line to trigger the split to the owner (a lease paid into ROCA1's account): split it here.
    if v_rent_part = 0 and v_fee_part > 0 and v_entry3 is not null and roca_split_unit(r.lease_id, r.id) is not null
       and r.paid_on >= coalesce((select value from portal_settings where key = 'roca_rent_split_from')::date, '2026-10-12'::date) then
      begin
        perform roca_rent_split_apply(r.lease_id, v_entry3, v_fee_part, r.paid_on);
      exception when others then
        insert into email_outbox (to_email, subject, html, kind) values (coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org'),
          'Unit late-fee payment could not be split automatically',
          '<p>A tenant late-fee payment of ' || to_char(v_fee_part, 'FM$999,990.00') || ' posted, but the automatic split to the owner failed: ' || repair_esc(sqlerrm) || '. Please handle it by hand on the Rent deductions page.</p>', 'roca_split_error');
      end;
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

-- ---------------------------------------------------------------------------
-- lease_payment_reverse: late fee off first, then the door part, then rent, then deposit (from 20261110080000)
CREATE OR REPLACE FUNCTION public.lease_payment_reverse(p_report uuid, p_amount numeric, p_reason text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r payment_reports; v_amt numeric; v_entry bigint; v_orig bigint; v_rp numeric; v_dp numeric; v_rr numeric; v_dr numeric; v_rent_rev numeric; v_dep_rev numeric; v_fp numeric; v_fr numeric; v_fee_rev numeric := 0;
        v_kp numeric; v_kr numeric; v_door_rev numeric := 0;
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
           coalesce(sum(amount) filter (where kind = 'reversal' and gl_account = 'Late Fee Income'), 0),
           coalesce(-sum(amount) filter (where kind = 'payment' and gl_account = 'Door Lock Charge'), 0),
           coalesce(sum(amount) filter (where kind = 'reversal' and gl_account = 'Door Lock Charge'), 0)
      into v_rp, v_dp, v_rr, v_dr, v_fp, v_fr, v_kp, v_kr from lease_ledger_entries where payment_report_id = r.id;
    if v_rp + v_dp + v_fp + v_kp = 0 then
      v_rent_rev := v_amt; v_dep_rev := 0;
    else
      -- The late-fee part was applied last, so it comes off first, then the door charge part, then rent, then the deposit.
      v_fee_rev := least(v_amt, greatest(v_fp - v_fr, 0));
      v_door_rev := least(v_amt - v_fee_rev, greatest(v_kp - v_kr, 0));
      v_rent_rev := least(v_amt - v_fee_rev - v_door_rev, greatest(v_rp - v_rr, 0)); v_dep_rev := v_amt - v_fee_rev - v_door_rev - v_rent_rev;
    end if;
    if v_fee_rev > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Late Fee Income', current_date, 'reversal', 'Payment reversed', r.method, 'Payment reversed: ' || trim(p_reason) || ' (late fee)', v_fee_rev, 'payment_reversal',
              'Reverses the late-fee part of the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept. By ' || coalesce(p_by, 'system') || '.', r.id)
      returning id into v_entry;
    end if;
    if v_door_rev > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, description, amount, source, correction_note, payment_report_id)
      values (r.lease_id, 'Door Lock Charge', current_date, 'reversal', 'Payment reversed', r.method, 'Payment reversed: ' || trim(p_reason) || ' (basement door charge)', v_door_rev, 'payment_reversal',
              'Reverses the basement door charge part of the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept. By ' || coalesce(p_by, 'system') || '.', r.id)
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
  if r.lease_id is not null and r.ledger_entry_id is not null then perform roca_rent_split_reverse(r.lease_id, r.ledger_entry_id, v_rent_rev + v_fee_rev, p_reason); end if;
  update payment_reports set reversed_amount = reversed_amount + v_amt, reversed_at = now(), reversed_reason = trim(p_reason), reversed_by = p_by,
         status = case when reversed_amount + v_amt >= amount then 'reversed' else status end
   where id = r.id;
  return jsonb_build_object('reversed', v_amt, 'entry', v_entry);
end;
$function$;
