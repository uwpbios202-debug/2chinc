-- Owners pay association dues online the same way tenants pay rent: they
-- send money (Zelle, PayPal, Cash App, bank transfer) and report it in the
-- owner portal; the report is verified from the bank side (Chase CSV, payment
-- alert emails) or by staff, and only then posted to the association ledger.
--
-- Association money is ROCA1's, not 2nd Chance Housing's, so owners get their
-- own pay-to settings (owner_pay_*). A method only shows when it is set.

alter table payment_reports alter column tenant_id drop not null;
alter table payment_reports add column if not exists owner_id uuid references condo_owners(id);
alter table payment_reports add column if not exists condo_account_id uuid references condo_ledger_accounts(id);
alter table payment_reports drop constraint if exists payment_reports_payer_check;
alter table payment_reports add constraint payment_reports_payer_check check (tenant_id is not null or owner_id is not null);
alter table condo_ledger_entries add column if not exists payment_report_id uuid references payment_reports(id);

insert into portal_settings (key, value) values
  ('owner_pay_zelle_to', ''), ('owner_pay_zelle_name', 'ROCA1'), ('owner_pay_zelle_qr', ''),
  ('owner_pay_paypal_link', ''), ('owner_pay_cashapp_tag', ''),
  ('owner_pay_memo', 'Put your unit number in the memo so we can match your payment.')
on conflict (key) do nothing;

-- Verify = post once to the right ledger.
create or replace function payment_post(p_report uuid, p_receipt uuid, p_source text, p_by text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare r payment_reports; v_entry bigint; v_label text;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null or r.status <> 'pending' then return; end if;
  v_label := initcap(replace(r.method, '_', ' ')) || ' payment';
  if r.condo_account_id is not null then
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, origin, entered_by, correction_note, payment_report_id)
    values (r.condo_account_id, 'Association Fee Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
            'Payment by ' || coalesce(r.payer_name, (select name from condo_owners where id = r.owner_id)), -r.amount, 'staff', coalesce(p_by, 'system'),
            'Reported online; verified via ' || p_source || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
    returning id into v_entry;
  elsif r.lease_id is not null then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note)
    values (r.lease_id, 'Rent Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
            'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)), -r.amount, 'payment_report',
            'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'))
    returning id into v_entry;
  elsif r.land_contract_id is not null then
    insert into land_contract_ledger (contract_id, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.land_contract_id, r.paid_on, 'payment', v_label || ' (verified)', 'Payment by ' || coalesce(r.payer_name, ''), -r.amount, 'payment_report',
            'Verified via ' || p_source);
  end if;
  update payment_reports set status = 'verified', verified_at = now(), verified_by = p_by, verification_source = p_source,
         bank_receipt_id = p_receipt, ledger_entry_id = v_entry where id = r.id;
  if p_receipt is not null then update bank_receipts set matched_report_id = r.id where id = p_receipt; end if;
end;
$$;
revoke all on function payment_post(uuid, uuid, text, text) from public, anon, authenticated;

-- Same matching rules as before; the payer is the tenant or the owner, and an
-- owner's memo can carry the unit number or account # (PIN).
create or replace function payments_auto_match()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare rec record; n int := 0;
begin
  for rec in
    with cand as (
      select b.id as receipt_id, r.id as report_id, b.source
      from bank_receipts b
      join payment_reports r on r.status = 'pending' and r.amount = b.amount and abs(b.posted_on - r.paid_on) <= 4
      left join tenants t on t.id = r.tenant_id
      left join condo_owners o on o.id = r.owner_id
      left join leases l on l.id = r.lease_id
      left join condo_ledger_accounts ca on ca.id = r.condo_account_id
      left join condo_units cu on cu.id = ca.unit_id
      where b.matched_report_id is null and not b.ignored and b.amount > 0
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
      and (select count(*) from cand x where x.report_id = c.report_id) = 1
  loop
    perform payment_post(rec.report_id, rec.receipt_id, case rec.source when 'chase_csv' then 'bank_csv' when 'email_alert' then 'email_alert' when 'stripe' then 'stripe' else 'staff' end, 'system');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function payments_auto_match() from public, anon, authenticated;
grant execute on function payments_auto_match() to service_role;

-- Staff queue now includes owners' reports, labelled by association unit.
create or replace function payments_staff_queue()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reports', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
        'tenant', coalesce(t.name, o.name || ' (owner)'),
        'account_number', coalesce(l.legacy_lease_number, cu.pin),
        'unit', coalesce(u.unit_number, case when cu.unit_number is not null then 'ROCA ' || cu.unit_number || ' dues' end),
        'receipt', (select to_jsonb(b) - 'raw' from bank_receipts b where b.id = r.bank_receipt_id)) order by r.created_at desc)
      from payment_reports r left join tenants t on t.id = r.tenant_id left join condo_owners o on o.id = r.owner_id
      left join leases l on l.id = r.lease_id left join rental_units u on u.id = l.unit_id
      left join condo_ledger_accounts ca on ca.id = r.condo_account_id left join condo_units cu on cu.id = ca.unit_id
      where r.created_at > now() - interval '120 days'), '[]'::jsonb),
    'unmatched_receipts', coalesce((select jsonb_agg(to_jsonb(b) - 'raw' order by b.posted_on desc)
      from bank_receipts b where b.matched_report_id is null and b.assigned_lease_id is null and not b.ignored and b.posted_on > current_date - 120), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner
-- ---------------------------------------------------------------------------
create or replace function condo_owner_pay_options()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not condo_session_ok() or condo_owner_for_email(auth.email()) is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(key, value) from portal_settings where key like 'owner_pay_%' and value <> ''), '{}'::jsonb);
end;
$$;
revoke all on function condo_owner_pay_options() from public, anon;
grant execute on function condo_owner_pay_options() to authenticated;

create or replace function condo_report_payment(p_unit_number text, p_method text, p_amount numeric, p_paid_on date, p_code text, p_payer text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_unit uuid; v_acct uuid; r payment_reports;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 200000 then raise exception 'Enter the amount you paid.'; end if;
  if p_paid_on is null or p_paid_on > current_date + 1 or p_paid_on < current_date - 60 then raise exception 'Enter the date you paid (within the last 60 days).'; end if;
  select s.unit_id into v_unit from condo_ownerships s join condo_units u on u.id = s.unit_id
   where s.owner_id = v_owner and s.is_current and u.unit_number = p_unit_number;
  if v_unit is null then raise exception 'Choose one of your units.'; end if;
  v_acct := condo_billing_account(v_unit);
  insert into payment_reports (owner_id, condo_account_id, method, amount, paid_on, confirmation_code, payer_name, note)
  values (v_owner, v_acct, case when p_method in ('zelle', 'cashapp', 'paypal', 'bank_transfer', 'money_order', 'check', 'cash', 'other') then p_method else 'other' end,
          round(p_amount, 2), p_paid_on, nullif(trim(coalesce(p_code, '')), ''), nullif(trim(coalesce(p_payer, '')), ''), left(nullif(trim(coalesce(p_note, '')), ''), 500))
  returning * into r;
  perform payments_auto_match();
  return jsonb_build_object('id', r.id, 'status', (select status from payment_reports where id = r.id));
end;
$$;
revoke all on function condo_report_payment(text, text, numeric, date, text, text, text) from public, anon;
grant execute on function condo_report_payment(text, text, numeric, date, text, text, text) to authenticated;

create or replace function condo_my_payment_reports()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'unit_number', u.unit_number, 'method', r.method, 'amount', r.amount, 'paid_on', r.paid_on,
      'status', r.status, 'confirmation_code', r.confirmation_code, 'reject_reason', r.reject_reason, 'created_at', r.created_at) order by r.created_at desc)
    from payment_reports r left join condo_ledger_accounts a on a.id = r.condo_account_id left join condo_units u on u.id = a.unit_id
    where r.owner_id = v_owner), '[]'::jsonb);
end;
$$;
revoke all on function condo_my_payment_reports() from public, anon;
grant execute on function condo_my_payment_reports() to authenticated;

-- The past-due email and statements now point owners to paying online.
update portal_settings set value = 'Pay online in your owner portal (Zelle and other apps), or mail a check or money order payable to ROCA1 to 6626 North Bourbon Street, Milwaukee, WI 53224 with your unit number on it.'
 where key = 'dues_pay_instructions' and value like 'Mail a check%';

-- Receipts: owners get one too, with their association balance.
create or replace function payment_receipt_trigger()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare t tenants; o condo_owners; v_addr text; v_bal numeric; v_unit text;
begin
  if new.status = 'verified' and (old.status is distinct from 'verified') then
    if new.owner_id is not null then
      select * into o from condo_owners where id = new.owner_id;
      select u.unit_number, (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a2 on a2.id = e.account_id
                             where a2.ownership_id = a.ownership_id and not a2.excluded)
        into v_unit, v_bal from condo_ledger_accounts a join condo_units u on u.id = a.unit_id where a.id = new.condo_account_id;
      if o.email is not null then
        insert into email_outbox (to_email, subject, html, kind) values (o.email, 'Association payment received — thank you',
          '<p>Hi ' || split_part(o.name, ' ', 1) || ',</p><p>We received your payment of <b>' || to_char(new.amount, 'FM$999,990.00') || '</b> (' ||
          replace(new.method, '_', ' ') || ', ' || to_char(new.paid_on, 'FMMM/FMDD/YYYY') || ') for Unit ' || coalesce(v_unit, '') ||
          ' at Royal Orleans Condominium.</p><p>Your association balance is now <b>' || to_char(coalesce(v_bal, 0), 'FM$999,999,990.00') || '</b>.</p>' ||
          '<p>Receipt reference: ' || upper(left(new.id::text, 8)) || '</p><p>Royal Orleans Condominium – Addition One<br>managed by 2nd Chance Housing</p>', 'receipt');
      end if;
      return new;
    end if;
    select * into t from tenants where id = new.tenant_id;
    select u.address into v_addr from leases l join rental_units u on u.id = l.unit_id where l.id = new.lease_id;
    select coalesce(sum(amount), 0) into v_bal from lease_ledger_entries where lease_id = new.lease_id;
    if t.email is not null then
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Payment received — thank you',
        '<p>Hi ' || split_part(t.name, ' ', 1) || ',</p><p>We received your payment of <b>' || to_char(new.amount, 'FM$999,990.00') || '</b> (' ||
        replace(new.method, '_', ' ') || ', ' || to_char(new.paid_on, 'FMMM/FMDD/YYYY') || ')' || coalesce(' for ' || v_addr, '') || '.</p>' ||
        case when new.lease_id is not null then '<p>Your balance is now <b>' || to_char(v_bal, 'FM$999,990.00') || '</b>.</p>' else '' end ||
        '<p>Receipt reference: ' || upper(left(new.id::text, 8)) || '</p><p>2nd Chance Housing</p>', 'receipt');
    end if;
  end if;
  return new;
end;
$$;
