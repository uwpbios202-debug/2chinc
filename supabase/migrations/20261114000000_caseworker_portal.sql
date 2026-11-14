-- Caseworker portal (Stephen, 10/22/2026).
-- A caseworker (an agency's contact for a client) signs in with an emailed code and sees ONLY their clients: the signed lease, ROCA1's signed W-9, the balance,
-- and the ways to pay. Caseworkers can pay ONLY to what the lease names (ROCA1, the agent): ROCA1's Stripe account, ROCA1's bank, or a check to ROCA1.
-- A tenant's own payments are NOT rerouted: this is per payment, never per lease. The agency's amount is never fixed (no split), any amount any month.
-- ROCA1's routing and account numbers are never in a file: they are entered in portal_settings (caseworker_pay_routing / caseworker_pay_account).

-- 1. Payments from an agency: who paid, and the account the money really landed in.
alter table stripe_payments add column if not exists caseworker_id uuid references caseworkers(id) on delete set null;
alter table stripe_payments drop constraint if exists stripe_payments_origin_check;
alter table stripe_payments add constraint stripe_payments_origin_check check (origin = any (array['pay_now','autopay','caseworker']));
alter table payment_reports add column if not exists caseworker_id uuid references caseworkers(id) on delete set null;
alter table payment_reports add column if not exists received_account_id uuid references bank_accounts(id);

insert into portal_settings (key, value) values
  ('session_idle_days_caseworker', '45'), ('session_max_days_caseworker', '180'),
  ('caseworker_pay_payee', 'Royal Orleans Condominium - Addition One, Inc. (ROCA1)'),
  ('caseworker_pay_mail', '6626 N Bourbon St, Milwaukee, WI 53224'),
  ('caseworker_pay_routing', ''), ('caseworker_pay_account', ''),
  ('roca1_w9_ein', '')
on conflict (key) do nothing;

-- 2. Who is a caseworker.
create or replace function caseworker_is_me() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from caseworkers where active and lower(email) = lower(auth.email()));
$$;
revoke all on function caseworker_is_me() from public, anon;
grant execute on function caseworker_is_me() to authenticated;

-- 3. Sign-in plumbing (patched from the live definitions).
CREATE OR REPLACE FUNCTION public.condo_email_on_file(p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email))
      or exists (select 1 from contractor_vendor_ids(p_email))
      or exists (select 1 from investors where active and lower(email) = lower(p_email))
      or exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email))
      or exists (select 1 from caseworkers where active and lower(email) = lower(p_email));
$function$;

CREATE OR REPLACE FUNCTION public.session_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when condo_is_staff() then 'staff' when condo_owner_for_email(auth.email()) is not null then 'owner'
              when exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())) then 'agent'
              when exists (select 1 from resident_tenant_ids(auth.email())) then 'resident'
              when field_is_staff() then 'field' when exists (select 1 from contractor_vendor_ids(auth.email())) then 'contractor'
              when seller_is_me() then 'seller'
              when caseworker_is_me() then 'caseworker'
              else 'investor' end;
$function$;

CREATE OR REPLACE FUNCTION public.condo_whoami()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_contractor boolean := exists (select 1 from contractor_vendor_ids(auth.email()));
  v_investor boolean := investor_is_me();
  v_seller boolean := seller_is_me();
  v_caseworker boolean := caseworker_is_me();
  v_phone text;
  v_name text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  if not session_fresh() then   -- this remembered device has expired: the page signs out and asks for a new code
    return jsonb_build_object('role', 'expired');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor or v_investor or v_seller or v_caseworker) then
    return jsonb_build_object('role', 'none');
  end if;
  select case when o = 4 and n ~* '\m(inc|llc|ltd|corp|trust|association|company|housing)\M'
              then regexp_replace(trim(n), '[,.]?\s*(inc|llc|ltd|corp)\.?$', '', 'i')
              else split_part(trim(n), ' ', 1) end into v_name from (
    select name as n, 1 as o from condo_staff where lower(email) = lower(auth.email())
    union all select name, 2 from field_staff where active and lower(email) = lower(auth.email())
    union all select name, 3 from portal_admins where lower(email) = lower(auth.email())
    union all select name, 4 from condo_owners where id = v_owner
    union all select name, 5 from land_contract_sellers where active and lower(email) = lower(auth.email())
    union all select name, 6 from caseworkers where active and lower(email) = lower(auth.email())
  ) s where coalesce(trim(n), '') <> '' order by o limit 1;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' when v_contractor then 'contractor' when v_seller then 'seller' when v_caseworker then 'caseworker' else 'investor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'is_investor', v_investor,
    'is_seller', v_seller,
    'is_caseworker', v_caseworker,
    'first_name', v_name,
    'mfa_required', mfa_required(),
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$function$;

-- 4. A deposit for an agency's payment belongs in ROCA1's account, not the lease's usual one (patched from the live definition).
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
    if v_rent_part = 0 and v_fee_part > 0 and v_entry3 is not null and roca_routed_unit(r.lease_id) is not null
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

-- 5. The Stripe payment of an agency posts under the agency's name, flagged as received by ROCA1 (patched from the live definition).
create or replace function stripe_payment_succeeded(p_intent text, p_method_type text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s stripe_payments; v_report uuid;
begin
  select * into s from stripe_payments where payment_intent = p_intent for update;
  if s.id is null then return jsonb_build_object('error', 'unknown payment intent'); end if;
  if s.status = 'succeeded' then return jsonb_build_object('ok', true, 'already', true); end if;
  insert into payment_reports (tenant_id, owner_id, condo_account_id, lease_id, land_contract_id, method, amount, paid_on, confirmation_code, note, caseworker_id, received_account_id, payer_name)
  values (s.tenant_id, s.owner_id, s.condo_account_id, s.lease_id, s.land_contract_id,
          case when coalesce(p_method_type, s.method_type) = 'card' then 'stripe_card' else 'stripe_bank' end,
          s.amount, (s.created_at at time zone 'America/Chicago')::date, p_intent,
          case when s.owner_id is not null then 'Association dues paid online' when s.origin = 'autopay' then 'Autopay' when s.origin = 'caseworker' then 'Paid online by the agency' else 'Paid online' end,
          s.caseworker_id, case when s.caseworker_id is not null then bank_account_by_key('first_citizens_roca1') end,
          case when s.caseworker_id is not null then (select coalesce(nullif(c.agency, ''), 'Agency') || ' (' || c.name || ')' from caseworkers c where c.id = s.caseworker_id) end)
  returning id into v_report;
  perform payment_post(v_report, null, 'stripe', 'Stripe');
  update stripe_payments set status = 'succeeded', method_type = coalesce(p_method_type, method_type), payment_report_id = v_report, updated_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'report', v_report);
end;
$$;

-- 6. The caseworker's read-only view: their clients' leases, balances and recent payments. Nobody else's.
create or replace function caseworker_my_clients() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cw uuid;
begin
  if auth.uid() is null or not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  select id into v_cw from caseworkers where active and lower(email) = lower(auth.email());
  if v_cw is null then raise exception 'Caseworker sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'start_date' desc) from (
    select distinct on (l.id) jsonb_build_object(
      'lease_id', l.id, 'unit', ru.address, 'tenants', l.tenants_label, 'status', l.status, 'start_date', l.start_date, 'rent', l.rent,
      'balance', (select coalesce(sum(e.amount), 0) from lease_ledger_entries e where e.lease_id = l.id),
      'has_lease_pdf', exists (select 1 from lease_signing_docs d where d.id = l.signing_doc_id and d.executed_pdf_path is not null),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('date', p.entry_date, 'amount', -p.amount, 'note', p.description) order by p.entry_date desc, p.id desc)
          from (select e.* from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'payment' order by e.entry_date desc, e.id desc limit 12) p), '[]'::jsonb)) as x
    from caseworker_clients cc
    join lease_tenants lt on lt.tenant_id = cc.tenant_id
    join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
    join rental_units ru on ru.id = l.unit_id
    where cc.caseworker_id = v_cw) s), '[]'::jsonb);
end;
$$;
revoke all on function caseworker_my_clients() from public, anon;
grant execute on function caseworker_my_clients() to authenticated;

-- 7. How to pay (ROCA1 only). The numbers come from portal_settings; they are shown only to a signed-in caseworker.
create or replace function caseworker_pay_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not caseworker_is_me() or not condo_session_ok() then raise exception 'Caseworker sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'payee', (select value from portal_settings where key = 'caseworker_pay_payee'),
    'mail', (select value from portal_settings where key = 'caseworker_pay_mail'),
    'routing', nullif((select value from portal_settings where key = 'caseworker_pay_routing'), ''),
    'account', nullif((select value from portal_settings where key = 'caseworker_pay_account'), ''),
    'stripe', coalesce((select value from portal_settings where key = 'stripe_enabled_roca1'), 'off') = 'on' and coalesce((select value from portal_settings where key = 'stripe_enabled'), 'off') = 'on');
end;
$$;
revoke all on function caseworker_pay_info() from public, anon;
grant execute on function caseworker_pay_info() to authenticated;

-- 8. Does this lease belong to a client of the signed-in caseworker? (the edge function asks with the caseworker's own session)
create or replace function caseworker_owns_lease(p_lease uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cw uuid;
begin
  select id into v_cw from caseworkers where active and lower(email) = lower(auth.email());
  if v_cw is null or not condo_session_ok() then raise exception 'Caseworker sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from caseworker_clients cc join lease_tenants lt on lt.tenant_id = cc.tenant_id join leases l on l.id = lt.lease_id
                  where cc.caseworker_id = v_cw and l.id = p_lease and l.status in ('active', 'future')) then
    raise exception 'That lease is not one of your clients' using errcode = '42501';
  end if;
  return jsonb_build_object('caseworker_id', v_cw,
    'tenant_id', (select lt.tenant_id from lease_tenants lt where lt.lease_id = p_lease order by lt.tenant_id limit 1));
end;
$$;
revoke all on function caseworker_owns_lease(uuid) from public, anon;
grant execute on function caseworker_owns_lease(uuid) to authenticated;
