-- Staff enter tenant payments and charges by hand on a lease ledger (Stephen, 11/3/2026: "any staff member must see the tenant
-- ledger and a button to enter payments and another button to enter charges"). Page: /leasing/leases/ (click a lease).
-- A payment is recorded as a payment report and posted through payment_post, so it follows the same rules as every other
-- payment: security deposit first (move-in), then rent, then open late fees, leftover is rent credit; the ROCA1 split runs
-- for routed leases; the tenant gets the usual receipt; it can be reversed with payments_staff_reverse.
-- A charge is one ledger line (source 'staff'). A mistaken charge is undone with a reversal line; the original is kept.
-- Nothing here touches existing lines. No new tables.

create or replace function lease_staff_record_payment(p_lease uuid, p_method text, p_amount numeric, p_paid_on date,
  p_reference text default null, p_payer text default null, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_tenant uuid; v_id uuid; v_amt numeric := round(p_amount, 2);
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from leases where id = p_lease) then raise exception 'Lease not found'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if p_paid_on is null or p_paid_on > current_date then raise exception 'Enter the date it was paid (not a future date)'; end if;
  if p_paid_on < current_date - 366 then raise exception 'That date is more than a year ago; ask the office manager'; end if;
  if coalesce(p_method, '') not in ('check', 'money_order', 'cash', 'zelle', 'bank_transfer', 'other') then raise exception 'Choose how it was paid'; end if;
  select lt.tenant_id into v_tenant from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = p_lease order by t.name limit 1;
  if v_tenant is null then raise exception 'This lease has no tenant on file'; end if;
  insert into payment_reports (tenant_id, lease_id, method, amount, paid_on, confirmation_code, payer_name, note, received_account_id)
  values (v_tenant, p_lease, p_method, v_amt, p_paid_on, nullif(trim(coalesce(p_reference, '')), ''), nullif(trim(coalesce(p_payer, '')), ''),
          'Entered by staff (' || auth.email() || ')' || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''), lease_receiving_account(p_lease))
  returning id into v_id;
  perform payment_post(v_id, null, 'staff', auth.email());
  return jsonb_build_object('report', v_id, 'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = p_lease));
end $$;
revoke all on function lease_staff_record_payment(uuid, text, numeric, date, text, text, text) from public, anon;
grant execute on function lease_staff_record_payment(uuid, text, numeric, date, text, text, text) to authenticated, service_role;

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
    when 'other'    then v_gl := 'Other Income';               v_label := 'Other charge';
    else raise exception 'Choose the type of charge';
  end case;
  if p_type = 'other' and coalesce(trim(p_description), '') = '' then raise exception 'Describe the charge'; end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (p_lease, v_gl, p_date, 'charge', 'Charge', coalesce(nullif(trim(coalesce(p_description, '')), ''), v_label), v_amt, 'staff',
          'Entered by ' || auth.email() || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function lease_staff_post_charge(uuid, text, numeric, date, text, text) from public, anon;
grant execute on function lease_staff_post_charge(uuid, text, numeric, date, text, text) to authenticated, service_role;

-- Undo a charge staff entered by mistake: a reversal line for the same amount; the original stays.
create or replace function lease_staff_reverse_charge(p_entry bigint, p_reason text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare e lease_ledger_entries; v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into e from lease_ledger_entries where id = p_entry for update;
  if e.id is null or e.kind <> 'charge' or e.source <> 'staff' then raise exception 'Only a charge entered by staff can be reversed here'; end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the charge is reversed'; end if;
  if exists (select 1 from lease_ledger_entries where lease_id = e.lease_id and source = 'staff_reversal' and correction_note like 'Reverses charge line ' || e.id || '.%') then
    raise exception 'That charge is already reversed';
  end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (e.lease_id, e.gl_account, current_date, 'reversal', 'Charge reversed', 'Charge reversed: ' || trim(p_reason), -e.amount, 'staff_reversal',
          'Reverses charge line ' || e.id || '. ' || 'Original kept. By ' || auth.email() || '.')
  returning id into v_id;
  return v_id;
end $$;
revoke all on function lease_staff_reverse_charge(bigint, text) from public, anon;
grant execute on function lease_staff_reverse_charge(bigint, text) to authenticated, service_role;

-- The ledger now also gives each line's id, source and its payment (so the page can offer Reverse).
create or replace function rentals_staff_ledger(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', e.id, 'date', e.entry_date, 'gl', e.gl_account, 'kind', e.kind, 'type', e.raw_type, 'description', e.description,
      'amount', e.amount, 'note', e.correction_note, 'source', e.source, 'report', e.payment_report_id,
      'report_left', case when r.status = 'verified' then r.amount - r.reversed_amount end,
      'reversed', e.source = 'staff' and e.kind = 'charge' and exists (select 1 from lease_ledger_entries x where x.lease_id = e.lease_id
                     and x.source = 'staff_reversal' and x.correction_note like 'Reverses charge line ' || e.id || '.%'))
      order by e.entry_date, e.id)
    from lease_ledger_entries e left join payment_reports r on r.id = e.payment_report_id where e.lease_id = p_lease_id), '[]'::jsonb);
end;
$$;
