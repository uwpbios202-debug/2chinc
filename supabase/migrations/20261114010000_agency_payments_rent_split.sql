-- Agency (caseworker) payments into ROCA1 go through the same rent split as Unit 16 (Stephen, 10/22/2026).
-- Unit 18: the security deposit stays with ROCA1 (it is a separate ledger line, never split); from the RENT, the unit's association dues ($215 a month)
-- and anything else the owner owes ROCA1 come out first, and the rest is the owner's (a staff Zelle task). Tenants' OWN payments are not affected:
-- a payment is split only when its lease is routed to ROCA1 (as before) OR the payment itself was received into ROCA1's account (payment_reports.received_account_id).

create or replace function roca_split_unit(p_lease uuid, p_report uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    roca_routed_unit(p_lease),
    (select cu.unit_number from payment_reports pr
       join leases l on l.id = p_lease join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
      where pr.id = p_report and pr.received_account_id is not null and pr.received_account_id = bank_account_by_key('first_citizens_roca1')));
$$;
revoke all on function roca_split_unit(uuid, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.roca_rent_split_apply(p_lease uuid, p_entry bigint, p_amount numeric, p_paid_on date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_unit text := roca_split_unit(p_lease, (select e.payment_report_id from lease_ledger_entries e where e.id = p_entry)); o record; t roca_pma_terms; v_acct uuid; r record; take numeric; v_left numeric := p_amount;
  v_ded jsonb := '[]'::jsonb; v_ded_total numeric := 0; v_mgmt numeric := 0; v_ids bigint[] := '{}'; v_id bigint; v_net numeric; v_split uuid;
  v_phone text; v_office text := coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org');
  CAT jsonb := '{"fines_fees":"fines and fees","assessments":"special assessments","dues_current":"association dues","older_balance":"past-due dues"}';
begin
  if v_unit is null or p_amount <= 0 then return null; end if;
  if exists (select 1 from roca_rent_splits where lease_entry_id = p_entry) then return null; end if;
  select * into o from roca_unit_owner_on(v_unit, p_paid_on);
  if o.owner_id is null or o.name ~* '^2nd Chance' then return null; end if;   -- 2nd Chance's own unit: nothing to split
  v_acct := roca_unit_account(v_unit);
  for r in select * from roca_unit_open_items(v_unit, date_trunc('month', p_paid_on)::date, greatest(p_paid_on, current_date)) loop
    exit when v_left <= 0;
    take := least(v_left, r.open);
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note)
    values (v_acct, r.gl_account, p_paid_on, 'payment', 'Payment', 'rent_deduction',
      'Paid from your tenant''s rent (' || coalesce(CAT->>r.category, r.category) || ')', -take, 'staff', 'automation',
      'Tenant rent payment of ' || to_char(p_amount, 'FM$999,990.00') || ' on ' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ' went to ROCA1''s account; this is the part applied to your association account.')
    returning id into v_id;
    v_ids := v_ids || v_id;
    v_ded := v_ded || jsonb_build_object('category', r.category, 'gl_account', r.gl_account, 'amount', take);
    v_ded_total := v_ded_total + take; v_left := v_left - take;
  end loop;
  select * into t from roca_pma_terms where unit_number = v_unit;
  v_mgmt := least(greatest(v_left, 0), round(p_amount * coalesce(t.mgmt_fee_pct, 0) / 100, 2));
  v_net := greatest(v_left - v_mgmt, 0);
  select phone_mobile into v_phone from condo_owners where id = o.owner_id;
  insert into roca_rent_splits (unit_number, owner_id, owner_name, owner_email, owner_phone, lease_id, lease_entry_id, paid_on, rent_amount, to_roca1, deductions, mgmt_fee,
                                net_to_owner, condo_entry_ids, status)
  values (v_unit, o.owner_id, o.name, o.email, v_phone, p_lease, p_entry, p_paid_on, p_amount, v_ded_total, v_ded, v_mgmt, v_net, v_ids,
          case when v_net > 0 then 'zelle_due' else 'nothing_to_send' end)
  returning id into v_split;
  if v_net > 0 then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Zelle $' || to_char(v_net, 'FM999,990.00') || ' to ' || o.name || ' (Unit ' || v_unit || ')',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Management fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>To send to the owner by Zelle: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>Zelle to ' || repair_esc(o.name) || ': phone ' || repair_esc(coalesce(v_phone, '(none on file)')) || ', email ' || repair_esc(coalesce(o.email, '(none on file)'))
      || '.</p><p>After you send it, record the date and reference: <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a>.</p>', 'roca_zelle_due');
  end if;
  if o.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (o.email, 'Unit ' || v_unit || ': your tenant''s rent payment was received',
      '<p>Dear ' || repair_esc(o.name) || ',</p><p>Your tenant''s rent payment of ' || to_char(p_amount, 'FM$999,990.00') || ' (' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ') cleared.</p><ul>'
      || '<li>Paid to ROCA1 for your association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Management fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>' || case when v_net > 0 then 'Being sent to you by Zelle: ' else 'Left for you: ' end || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>See it in the owner portal: https://2ndchinc.org/association-owners/roca1/#statements</p><p>2nd Chance Housing, for ROCA1</p>', 'roca_rent_split');
  end if;
  return v_split;
end;
$function$;

CREATE OR REPLACE FUNCTION public.roca_rent_split_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.kind = 'payment' and new.gl_account = 'Rent Income' and new.amount < 0
     and new.entry_date >= coalesce((select value from portal_settings where key = 'roca_rent_split_from')::date, '2026-10-12'::date)
     and roca_split_unit(new.lease_id, new.payment_report_id) is not null then
    begin
      perform roca_rent_split_apply(new.lease_id, new.id, -new.amount + coalesce((select -sum(f.amount) from lease_ledger_entries f
                 where f.payment_report_id = new.payment_report_id and f.payment_report_id is not null and f.kind = 'payment' and f.gl_account = 'Late Fee Income'), 0), new.entry_date);
    exception when others then
      insert into email_outbox (to_email, subject, html, kind) values (coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org'),
        'Unit rent payment could not be split automatically',
        '<p>A tenant payment of ' || to_char(-new.amount, 'FM$999,990.00') || ' (lease ledger line ' || new.id || ') posted, but the automatic split to the owner''s association account failed: '
        || repair_esc(sqlerrm) || '. Please handle it by hand on the Rent deductions page.</p>', 'roca_split_error');
    end;
  end if;
  return new;
end;
$function$;

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
    v_entry := coalesce(v_entry2, v_entry3, v_entry);
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
