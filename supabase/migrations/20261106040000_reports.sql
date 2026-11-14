-- Printable reports (Stephen, 10/7/2026): "owners need to print reports and we need to print reports for the accountant."
--
-- Every report reads the ledgers as they are; nothing is estimated. Each returns one JSON shape the pages render
-- generically (site/accounting/reports/, site/assets/portal/reports.js):
--   { title, entity, source, period, columns: [{key, label, type: text|money|date|int}], rows: [...],
--     group_by?: key (subtotals per group), totals: {key: value}, notes: [...] }
--
-- Two entities, two bank accounts, never mixed: rent is 2nd Chance Housing Inc.'s (lease ledger, land contract
-- ledger); association dues are ROCA1's (condo ledger). Excluded association accounts (excluded = true) and the
-- local test records (rental property key 'test', condo units at "Test Way") are left out of every report.
--
-- Staff reports need the two-step staff sign-in. Owner and tenant reports show only the signed-in person's own units.
-- The housing-assistance report reads housing_assistance / assistance_ledger, built separately
-- (20261106010000); until those tables exist it returns an empty report with a note, so this file applies either way.

-- ---------------------------------------------------------------------------
-- Helpers
create or replace function report_staff_check()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
end $$;
revoke all on function report_staff_check() from public, anon, authenticated;

create or replace function report_unit_sort(p text)
returns int language sql immutable as $$ select coalesce(nullif(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '')::int, 9999); $$;

-- Leases that count (not the local test property), with a readable unit label and tenant names.
create or replace function report_leases()
returns table (lease_id uuid, unit_number text, property text, unit_label text, tenants text, status text, rent numeric,
               start_date date, end_date date, deposit_held numeric)
language sql stable security definer set search_path = public as $$
  select l.id, u.unit_number, p.name,
         case when p.key = 'roca1' then 'Unit ' || u.unit_number else p.name || coalesce(nullif(' #' || u.unit_number, ' #_'), '') end,
         coalesce((select string_agg(t.name, ', ' order by t.name) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id), l.tenants_label),
         l.status, l.rent, l.start_date, l.end_date, l.deposit_held
  from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
  where p.key is distinct from 'test';
$$;
revoke all on function report_leases() from public, anon, authenticated;

-- Association accounts that count.
create or replace function report_condo_accounts()
returns table (account_id uuid, unit_number text, owner_label text, is_current boolean)
language sql stable security definer set search_path = public as $$
  select a.id, u.unit_number,
         coalesce((select o.name from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.id = a.ownership_id), a.legacy_owner_label),
         coalesce((select s.is_current from condo_ownerships s where s.id = a.ownership_id), false)
  from condo_ledger_accounts a join condo_units u on u.id = a.unit_id
  where not a.excluded and u.address not ilike '%Test Way%';
$$;
revoke all on function report_condo_accounts() from public, anon, authenticated;

-- Ages an outstanding balance: payments pay the oldest charges first, so what is still owed is the newest charges.
-- p_dates / p_amts are the positive charges, any order. Returns buckets by days past the charge date.
create or replace function report_age(p_balance numeric, p_dates date[], p_amts numeric[], p_as_of date)
returns jsonb language plpgsql immutable as $$
declare left_ numeric := greatest(coalesce(p_balance, 0), 0); r record; take numeric; d int;
  b0 numeric := 0; b1 numeric := 0; b2 numeric := 0; b3 numeric := 0;
begin
  for r in select x.d, x.a from unnest(p_dates, p_amts) as x(d, a) where x.a > 0 order by x.d desc loop
    exit when left_ <= 0;
    take := least(left_, r.a); left_ := left_ - take; d := p_as_of - r.d;
    if d <= 30 then b0 := b0 + take; elsif d <= 60 then b1 := b1 + take; elsif d <= 90 then b2 := b2 + take; else b3 := b3 + take; end if;
  end loop;
  b3 := b3 + left_;   -- owed beyond every charge on file (e.g. an opening amount): oldest bucket
  return jsonb_build_object('d0_30', b0, 'd31_60', b1, 'd61_90', b2, 'd90p', b3);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Income by GL account by month (billed, collected, credits) — one entity at a time.
create or replace function report_income_by_gl(p_side text, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a from and to date.'; end if;
  with e as (
    select x.gl_account gl, date_trunc('month', x.entry_date)::date m, x.kind, x.amount
      from lease_ledger_entries x where p_side = 'rent' and x.lease_id in (select lease_id from report_leases()) and x.entry_date between p_from and p_to
    union all
    select x.gl_account, date_trunc('month', x.entry_date)::date, x.kind, x.amount
      from condo_ledger_entries x where p_side = 'association' and x.account_id in (select account_id from report_condo_accounts()) and x.entry_date between p_from and p_to
    union all
    select coalesce(x.legacy_gl, x.kind), date_trunc('month', x.entry_date)::date,
           case when x.kind in ('installment_due', 'rent_due', 'late_fee', 'deposit') then 'charge' else x.kind end, x.amount
      from land_contract_ledger x where p_side = 'land_contract' and x.entry_date between p_from and p_to
  ), g as (
    select gl, m,
      sum(amount) filter (where kind in ('charge', 'late_fee')) billed,
      -sum(amount) filter (where kind = 'payment') collected,
      -sum(amount) filter (where kind = 'in_kind') in_kind,
      -sum(amount) filter (where kind not in ('charge', 'late_fee', 'payment', 'in_kind')) credits
    from e group by gl, m)
  select coalesce(jsonb_agg(jsonb_build_object('gl', gl, 'month', to_char(m, 'YYYY-MM'), 'billed', coalesce(billed, 0), 'collected', coalesce(collected, 0),
           'in_kind', coalesce(in_kind, 0), 'credits', coalesce(credits, 0)) order by gl, m), '[]'::jsonb),
         jsonb_build_object('billed', coalesce(sum(billed), 0), 'collected', coalesce(sum(collected), 0), 'in_kind', coalesce(sum(in_kind), 0), 'credits', coalesce(sum(credits), 0))
    into v_rows, v_tot from g;
  return jsonb_build_object(
    'title', case p_side when 'rent' then 'Rental income by GL account' when 'association' then 'Association income by GL account' else 'Land contract activity by GL account' end,
    'entity', case p_side when 'association' then 'ROCA1 (Royal Orleans Condominium – Addition One)' else '2nd Chance Housing Inc.' end,
    'source', case p_side when 'rent' then 'Tenant lease ledgers' when 'association' then 'Association owner ledgers' else 'Land contract ledger (3446 N. 12th St.)' end,
    'period', jsonb_build_object('from', p_from, 'to', p_to), 'group_by', 'gl',
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'gl', 'label', 'GL account', 'type', 'text'), jsonb_build_object('key', 'month', 'label', 'Month', 'type', 'text'),
      jsonb_build_object('key', 'billed', 'label', 'Billed (charges)', 'type', 'money'), jsonb_build_object('key', 'collected', 'label', 'Collected (payments)', 'type', 'money'),
      jsonb_build_object('key', 'in_kind', 'label', 'Work in lieu', 'type', 'money'), jsonb_build_object('key', 'credits', 'label', 'Credits & adjustments', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Billed = charges and late fees posted in the month (accrual). Collected = payments posted in the month (cash), as each payment was split across GL accounts.',
      'Credits & adjustments = credits, applied deposits, refunds and reversals (shown as a positive reduction).',
      case when p_side = 'rent' then 'Security Deposit Liability is a liability, not income; it is listed so the totals tie to the ledgers.' else '' end));
end $$;
revoke all on function report_income_by_gl(text, date, date) from public, anon;
grant execute on function report_income_by_gl(text, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Receipts register: every payment received in the period, one line per receipt (an earlier report split one receipt
--    across several GL accounts; those lines are grouped back together here).
create or replace function report_receipts(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_tot jsonb; v_extra jsonb;
begin
  perform report_staff_check();
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a from and to date.'; end if;
  with r as (
    select 'Rent — 2nd Chance Housing Inc.' ledger, x.entry_date d, rl.unit_label unit, rl.tenants payer, x.method, x.check_number ref,
           -sum(x.amount) amount, string_agg(x.gl_account || ' ' || to_char(-x.amount, 'FM999,990.00'), '; ' order by x.id) split, rl.unit_number u
      from lease_ledger_entries x join report_leases() rl on rl.lease_id = x.lease_id
     where x.kind = 'payment' and x.entry_date between p_from and p_to
     group by x.lease_id, rl.unit_label, rl.tenants, rl.unit_number, x.entry_date, x.method, x.check_number
    union all
    select 'Association dues — ROCA1', x.entry_date, 'Unit ' || ca.unit_number, ca.owner_label, x.method, x.check_number,
           -sum(x.amount), string_agg(x.gl_account || ' ' || to_char(-x.amount, 'FM999,990.00'), '; ' order by x.id), ca.unit_number
      from condo_ledger_entries x join report_condo_accounts() ca on ca.account_id = x.account_id
     where x.kind = 'payment' and x.entry_date between p_from and p_to
     group by x.account_id, ca.unit_number, ca.owner_label, x.entry_date, x.method, x.check_number
    union all
    select 'Land contract — 3446 N. 12th St.', x.entry_date, '3446 N. 12th St.', c.buyers_label, null, null,
           -sum(x.amount), string_agg(coalesce(x.legacy_gl, '') || ' ' || to_char(-x.amount, 'FM999,990.00'), '; ' order by x.id), 'zz'
      from land_contract_ledger x join land_contracts c on c.id = x.contract_id
     where x.kind = 'payment' and x.entry_date between p_from and p_to
     group by x.contract_id, c.buyers_label, x.entry_date)
  select coalesce(jsonb_agg(jsonb_build_object('ledger', ledger, 'date', d, 'unit', unit, 'payer', payer, 'method', method, 'reference', ref,
           'amount', amount, 'split', split) order by ledger, d, report_unit_sort(u)), '[]'::jsonb),
         jsonb_build_object('amount', coalesce(sum(amount), 0))
    into v_rows, v_tot from r;
  -- Housing assistance agencies pay their share separately (assistance_ledger, 20261106010000); dynamic so this applies without it.
  if to_regclass('public.assistance_ledger') is not null and to_regclass('public.housing_assistance') is not null then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('ledger', 'Rent — housing assistance agencies', 'date', e.entry_date, 'unit', rl.unit_label,
               'payer', coalesce(h.agency_name, h.program) || ' (for ' || rl.tenants || ')', 'method', e.method, 'reference', e.reference,
               'amount', -e.amount, 'split', 'Agency share of rent', 'u', rl.unit_number)), '[]'::jsonb)
        from assistance_ledger e join housing_assistance h on h.id = e.assistance_id join report_leases() rl on rl.lease_id = e.lease_id
       where e.kind = 'payment' and e.entry_date between $1 and $2 $q$ into v_extra using p_from, p_to;
    if jsonb_array_length(v_extra) > 0 then
      select jsonb_agg(x - 'u' order by x->>'ledger', x->>'date', report_unit_sort(x->>'unit')) into v_rows
        from jsonb_array_elements(v_rows || v_extra) x;
      v_tot := jsonb_build_object('amount', (v_tot->>'amount')::numeric + (select sum((x->>'amount')::numeric) from jsonb_array_elements(v_extra) x));
    end if;
  end if;
  return jsonb_build_object('title', 'Receipts register', 'entity', '2nd Chance Housing Inc. and ROCA1 (kept apart by ledger)',
    'source', 'Payments posted to the tenant, association and land contract ledgers', 'period', jsonb_build_object('from', p_from, 'to', p_to),
    'group_by', 'ledger',
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'ledger', 'label', 'Ledger', 'type', 'text'), jsonb_build_object('key', 'date', 'label', 'Date', 'type', 'date'),
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'payer', 'label', 'Account', 'type', 'text'),
      jsonb_build_object('key', 'method', 'label', 'Method', 'type', 'text'), jsonb_build_object('key', 'reference', 'label', 'Check / ref', 'type', 'text'),
      jsonb_build_object('key', 'amount', 'label', 'Amount', 'type', 'money'), jsonb_build_object('key', 'split', 'label', 'GL split', 'type', 'text')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Posting date is the date the payment was entered on the ledger. Rent and association money go to separate bank accounts; subtotals are per ledger.'));
end $$;
revoke all on function report_receipts(date, date) from public, anon;
grant execute on function report_receipts(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Rent roll as of a date.
create or replace function report_rent_roll(p_as_of date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_as_of, current_date); v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  with r as (
    select rl.*, (select coalesce(sum(e.amount), 0) from lease_ledger_entries e where e.lease_id = rl.lease_id and e.entry_date <= d) bal
    from report_leases() rl
    where coalesce(rl.start_date, d) <= d and (rl.end_date is null or rl.end_date >= d) and rl.status in ('active', 'past', 'future')
      and (rl.status = 'active' or rl.end_date is not null))
  select coalesce(jsonb_agg(jsonb_build_object('unit', unit_label, 'tenants', tenants, 'start', start_date, 'end', end_date, 'rent', rent,
           'deposit', deposit_held, 'balance', bal) order by property, report_unit_sort(unit_number)), '[]'::jsonb),
         jsonb_build_object('rent', coalesce(sum(rent), 0), 'deposit', coalesce(sum(deposit_held), 0), 'balance', coalesce(sum(bal), 0))
    into v_rows, v_tot from r;
  return jsonb_build_object('title', 'Rent roll', 'entity', '2nd Chance Housing Inc.', 'source', 'Leases and tenant lease ledgers',
    'period', jsonb_build_object('as_of', d),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'tenants', 'label', 'Tenants', 'type', 'text'),
      jsonb_build_object('key', 'start', 'label', 'Lease start', 'type', 'date'), jsonb_build_object('key', 'end', 'label', 'Lease end', 'type', 'date'),
      jsonb_build_object('key', 'rent', 'label', 'Monthly rent', 'type', 'money'), jsonb_build_object('key', 'deposit', 'label', 'Deposit held', 'type', 'money'),
      jsonb_build_object('key', 'balance', 'label', 'Balance', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Leases in effect on the as-of date (an active lease with no end date counts). Rent is the current lease rent. Deposit held is the amount on file today, not as of the date.',
      'Balance is every ledger line dated on or before the as-of date (positive = the tenant owes).'));
end $$;
revoke all on function report_rent_roll(date) from public, anon;
grant execute on function report_rent_roll(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Tenant receivables aging.
create or replace function report_tenant_aging(p_as_of date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_as_of, current_date); v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  with b as (
    select rl.lease_id, rl.unit_label, rl.unit_number, rl.property, rl.tenants, rl.status,
           (select coalesce(sum(e.amount), 0) from lease_ledger_entries e where e.lease_id = rl.lease_id and e.entry_date <= d) bal
    from report_leases() rl),
  a as (
    select b.*, report_age(b.bal,
        (select array_agg(e.entry_date) from lease_ledger_entries e where e.lease_id = b.lease_id and e.entry_date <= d and e.amount > 0),
        (select array_agg(e.amount) from lease_ledger_entries e where e.lease_id = b.lease_id and e.entry_date <= d and e.amount > 0), d) ag
    from b where b.bal <> 0)
  select coalesce(jsonb_agg(jsonb_build_object('unit', unit_label, 'tenants', tenants, 'status', status, 'balance', bal,
           'd0_30', (ag->>'d0_30')::numeric, 'd31_60', (ag->>'d31_60')::numeric, 'd61_90', (ag->>'d61_90')::numeric, 'd90p', (ag->>'d90p')::numeric)
           order by property, report_unit_sort(unit_number), status), '[]'::jsonb),
         jsonb_build_object('balance', coalesce(sum(bal), 0), 'd0_30', coalesce(sum((ag->>'d0_30')::numeric), 0), 'd31_60', coalesce(sum((ag->>'d31_60')::numeric), 0),
           'd61_90', coalesce(sum((ag->>'d61_90')::numeric), 0), 'd90p', coalesce(sum((ag->>'d90p')::numeric), 0))
    into v_rows, v_tot from a;
  return jsonb_build_object('title', 'Tenant receivables aging', 'entity', '2nd Chance Housing Inc.', 'source', 'Tenant lease ledgers (current and former tenants)',
    'period', jsonb_build_object('as_of', d),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'tenants', 'label', 'Tenants', 'type', 'text'),
      jsonb_build_object('key', 'status', 'label', 'Lease', 'type', 'text'), jsonb_build_object('key', 'balance', 'label', 'Balance', 'type', 'money'),
      jsonb_build_object('key', 'd0_30', 'label', '0–30 days', 'type', 'money'), jsonb_build_object('key', 'd31_60', 'label', '31–60', 'type', 'money'),
      jsonb_build_object('key', 'd61_90', 'label', '61–90', 'type', 'money'), jsonb_build_object('key', 'd90p', 'label', 'Over 90', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Every lease with a non-zero balance on the as-of date. Payments are applied to the oldest charges first, so the amount still owed is aged from the newest charges.',
      'A negative balance is a credit (prepaid); credits are not aged.'));
end $$;
revoke all on function report_tenant_aging(date) from public, anon;
grant execute on function report_tenant_aging(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Security deposits held (today).
create or replace function report_deposits_held()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  with r as (
    select rl.unit_label, rl.unit_number, rl.property, rl.tenants, rl.status, rl.start_date, rl.deposit_held amt, 'Held' st, null::date due
      from report_leases() rl where rl.status in ('active', 'future') and coalesce(rl.deposit_held, 0) <> 0
    union all
    select rl.unit_label, rl.unit_number, rl.property, rl.tenants, rl.status, rl.start_date, coalesce(m.deposit_held, rl.deposit_held),
           'Moved out — statement not sent yet', m.deposit_due_by
      from report_leases() rl join move_outs m on m.lease_id = rl.lease_id
     where m.status not in ('deposit_sent', 'closed') and rl.status = 'past' and coalesce(m.deposit_held, rl.deposit_held, 0) <> 0)
  select coalesce(jsonb_agg(jsonb_build_object('unit', unit_label, 'tenants', tenants, 'start', start_date, 'status', st, 'due', due, 'amount', amt)
           order by property, report_unit_sort(unit_number)), '[]'::jsonb),
         jsonb_build_object('amount', coalesce(sum(amt), 0))
    into v_rows, v_tot from r;
  return jsonb_build_object('title', 'Security deposits held', 'entity', '2nd Chance Housing Inc.', 'source', 'Deposit on file for each lease (leases.deposit_held) and move-outs',
    'period', jsonb_build_object('as_of', current_date),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'tenants', 'label', 'Tenants', 'type', 'text'),
      jsonb_build_object('key', 'start', 'label', 'Lease start', 'type', 'date'), jsonb_build_object('key', 'status', 'label', 'Status', 'type', 'text'),
      jsonb_build_object('key', 'due', 'label', 'Statement due', 'type', 'date'), jsonb_build_object('key', 'amount', 'label', 'Deposit', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Today''s deposits, from the amount on file for each lease (the original tenant statements for earlier leases). The Security Deposit Liability lines in earlier ledgers are not used for this total.',
      'Moved-out tenants stay on the list until their itemized deposit statement is sent (21 days, Wis. Stat. § 704.28).'));
end $$;
revoke all on function report_deposits_held() from public, anon;
grant execute on function report_deposits_held() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Association dues by account for a period, with aging of the closing balance.
create or replace function report_association_dues(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a from and to date.'; end if;
  with a as (
    select ca.*,
      (select coalesce(sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date < p_from) opening,
      (select coalesce(sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date between p_from and p_to
         and e.kind in ('charge', 'late_fee') and e.gl_account in ('Association Fee Income', 'Association Dues')) dues,
      (select coalesce(sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date between p_from and p_to
         and e.kind in ('charge', 'late_fee') and e.gl_account = 'Late Fee Income') late,
      (select coalesce(sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date between p_from and p_to
         and e.kind in ('charge', 'late_fee') and e.gl_account not in ('Association Fee Income', 'Association Dues', 'Late Fee Income')) other,
      (select coalesce(-sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date between p_from and p_to and e.kind = 'payment') paid,
      (select coalesce(-sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date between p_from and p_to
         and e.kind not in ('charge', 'late_fee', 'payment')) credits,
      (select coalesce(sum(e.amount), 0) from condo_ledger_entries e where e.account_id = ca.account_id and e.entry_date <= p_to) closing
    from report_condo_accounts() ca),
  g as (select a.*, report_age(a.closing,
          (select array_agg(e.entry_date) from condo_ledger_entries e where e.account_id = a.account_id and e.entry_date <= p_to and e.amount > 0),
          (select array_agg(e.amount) from condo_ledger_entries e where e.account_id = a.account_id and e.entry_date <= p_to and e.amount > 0), p_to) ag
        from a where a.opening <> 0 or a.closing <> 0 or a.dues <> 0 or a.paid <> 0 or a.late <> 0 or a.other <> 0 or a.credits <> 0)
  select coalesce(jsonb_agg(jsonb_build_object('unit', unit_number, 'owner', owner_label || case when is_current then '' else ' (former)' end,
           'opening', opening, 'dues', dues, 'late', late, 'other', other, 'paid', paid, 'credits', credits, 'closing', closing,
           'd0_30', (ag->>'d0_30')::numeric, 'd31_60', (ag->>'d31_60')::numeric, 'd61_90', (ag->>'d61_90')::numeric, 'd90p', (ag->>'d90p')::numeric)
           order by report_unit_sort(unit_number), is_current desc, owner_label), '[]'::jsonb),
         jsonb_build_object('opening', coalesce(sum(opening), 0), 'dues', coalesce(sum(dues), 0), 'late', coalesce(sum(late), 0), 'other', coalesce(sum(other), 0),
           'paid', coalesce(sum(paid), 0), 'credits', coalesce(sum(credits), 0), 'closing', coalesce(sum(closing), 0),
           'd0_30', coalesce(sum((ag->>'d0_30')::numeric), 0), 'd31_60', coalesce(sum((ag->>'d31_60')::numeric), 0),
           'd61_90', coalesce(sum((ag->>'d61_90')::numeric), 0), 'd90p', coalesce(sum((ag->>'d90p')::numeric), 0))
    into v_rows, v_tot from g;
  return jsonb_build_object('title', 'Association dues by unit', 'entity', 'ROCA1 (Royal Orleans Condominium – Addition One)', 'source', 'Association owner ledgers',
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'owner', 'label', 'Account', 'type', 'text'),
      jsonb_build_object('key', 'opening', 'label', 'Opening', 'type', 'money'), jsonb_build_object('key', 'dues', 'label', 'Dues', 'type', 'money'),
      jsonb_build_object('key', 'late', 'label', 'Late fees', 'type', 'money'), jsonb_build_object('key', 'other', 'label', 'Other charges', 'type', 'money'),
      jsonb_build_object('key', 'paid', 'label', 'Paid', 'type', 'money'), jsonb_build_object('key', 'credits', 'label', 'Credits', 'type', 'money'),
      jsonb_build_object('key', 'closing', 'label', 'Closing', 'type', 'money'),
      jsonb_build_object('key', 'd0_30', 'label', '0–30', 'type', 'money'), jsonb_build_object('key', 'd31_60', 'label', '31–60', 'type', 'money'),
      jsonb_build_object('key', 'd61_90', 'label', '61–90', 'type', 'money'), jsonb_build_object('key', 'd90p', 'label', 'Over 90', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('One row per association account (a unit can have more than one, e.g. Unit 18). Excluded accounts are left out.',
      'Aging is of the closing balance on the "to" date; payments are applied to the oldest charges first. Other charges include legal, interest, repairs, cleaning, parking and fines.'));
end $$;
revoke all on function report_association_dues(date, date) from public, anon;
grant execute on function report_association_dues(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Land contract: principal and interest by year (actuarial, from land_contract_interest) and what was billed and paid.
create or replace function report_land_contract(p_as_of date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_as_of, current_date); v_rows jsonb := '[]'::jsonb; v_tot jsonb; c record; li jsonb; v_notes jsonb := '[]'::jsonb;
begin
  perform report_staff_check();
  for c in select * from land_contracts order by contract_date loop
    li := land_contract_interest(c.id, d);
    if li is null then
      v_notes := v_notes || to_jsonb('Contract with ' || c.buyers_label || ': terms not complete, no interest split.'); continue; end if;
    v_rows := v_rows || coalesce((select jsonb_agg(jsonb_build_object('contract', c.buyers_label || ' (seller ' || coalesce(c.seller, '?') || ')',
        'year', (y->>'year')::int,
        'due', (select coalesce(sum(e.amount), 0) from land_contract_ledger e where e.contract_id = c.id and e.kind in ('installment_due', 'rent_due') and extract(year from e.entry_date) = (y->>'year')::int and e.entry_date <= d),
        'paid', (y->>'paid')::numeric, 'principal', (y->>'principal')::numeric, 'interest', (y->>'interest')::numeric,
        'complete', case when (y->>'complete')::boolean then 'Full year' else 'Year to date' end))
      from jsonb_array_elements(li->'years') y), '[]'::jsonb);
    v_notes := v_notes || to_jsonb('Contract with ' || c.buyers_label || ': principal balance ' || to_char((li->>'principal_balance')::numeric, 'FM$999,990.00')
      || ', accrued unpaid interest ' || to_char((li->>'accrued_interest')::numeric, 'FM$999,990.00') || ' as of ' || to_char(d, 'FMMM/FMDD/YYYY') || '.');
  end loop;
  select jsonb_build_object('due', coalesce(sum((r->>'due')::numeric), 0), 'paid', coalesce(sum((r->>'paid')::numeric), 0),
         'principal', coalesce(sum((r->>'principal')::numeric), 0), 'interest', coalesce(sum((r->>'interest')::numeric), 0))
    into v_tot from jsonb_array_elements(v_rows) r;
  return jsonb_build_object('title', 'Land contract principal and interest by year', 'entity', '2nd Chance Housing Inc. (collecting)',
    'source', 'Land contract ledger; interest computed from the contract terms on each payment date (same method as the buyer portal)',
    'period', jsonb_build_object('as_of', d), 'group_by', 'contract',
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'contract', 'label', 'Contract', 'type', 'text'), jsonb_build_object('key', 'year', 'label', 'Year', 'type', 'int'),
      jsonb_build_object('key', 'due', 'label', 'Installments billed', 'type', 'money'), jsonb_build_object('key', 'paid', 'label', 'Paid', 'type', 'money'),
      jsonb_build_object('key', 'principal', 'label', 'Principal', 'type', 'money'), jsonb_build_object('key', 'interest', 'label', 'Interest', 'type', 'money'),
      jsonb_build_object('key', 'complete', 'label', '', 'type', 'text')),
    'rows', v_rows, 'totals', v_tot,
    'notes', v_notes || to_jsonb('Paid = installment payments only (late fees and the 2019 deposit are separate ledger lines).'::text));
end $$;
revoke all on function report_land_contract(date) from public, anon;
grant execute on function report_land_contract(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Work in lieu of rent: credits posted in the period.
create or replace function report_work_in_lieu(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a from and to date.'; end if;
  with r as (
    select rl.unit_label, rl.unit_number, rl.tenants, w.work_date, w.description, w.hours, w.value,
           (select a.title from work_agreements a where a.id = w.agreement_id) agreement, w.verified_by
      from work_logs w join report_leases() rl on rl.lease_id = w.lease_id
     where w.work_date between p_from and p_to)
  select coalesce(jsonb_agg(jsonb_build_object('unit', unit_label, 'tenants', tenants, 'date', work_date, 'agreement', agreement,
           'description', description, 'hours', hours, 'value', value) order by report_unit_sort(unit_number), work_date), '[]'::jsonb),
         jsonb_build_object('value', coalesce(sum(value), 0), 'hours', coalesce(sum(hours), 0))
    into v_rows, v_tot from r;
  return jsonb_build_object('title', 'Work in lieu of rent', 'entity', '2nd Chance Housing Inc.', 'source', 'Work logs (each credit is also a line on the tenant ledger)',
    'period', jsonb_build_object('from', p_from, 'to', p_to), 'group_by', 'unit',
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'tenants', 'label', 'Tenant', 'type', 'text'),
      jsonb_build_object('key', 'date', 'label', 'Date', 'type', 'date'), jsonb_build_object('key', 'agreement', 'label', 'Agreement', 'type', 'text'),
      jsonb_build_object('key', 'description', 'label', 'Work', 'type', 'text'), jsonb_build_object('key', 'hours', 'label', 'Hours', 'type', 'int'),
      jsonb_build_object('key', 'value', 'label', 'Credit', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Rent paid in services rather than cash. Ask the accountant how in-kind rent should be reported.'));
end $$;
revoke all on function report_work_in_lieu(date, date) from public, anon;
grant execute on function report_work_in_lieu(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Housing assistance receivable (what agencies owe for their share of rent). Tables come from 20261106010000;
--    read with dynamic SQL so this file applies before they exist. Ledger sign: due lines positive, payments negative
--    (like every other ledger here); the balance is the sum.
create or replace function report_assistance(p_as_of date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_as_of, current_date); v_rows jsonb; v_tot jsonb;
begin
  perform report_staff_check();
  if to_regclass('public.housing_assistance') is null or to_regclass('public.assistance_ledger') is null then
    return jsonb_build_object('title', 'Housing assistance receivable', 'entity', '2nd Chance Housing Inc.', 'source', 'Housing assistance ledger',
      'period', jsonb_build_object('as_of', d), 'columns', '[]'::jsonb, 'rows', '[]'::jsonb, 'totals', '{}'::jsonb,
      'notes', jsonb_build_array('Housing assistance is not set up in this database yet.'));
  end if;
  execute $q$
    with h as (select to_jsonb(x) j, x.id, x.lease_id from housing_assistance x),
    r as (
      select rl.unit_label, rl.unit_number, rl.tenants,
             coalesce(h.j->>'agency_name', h.j->>'agency', h.j->>'program', '') agency,
             coalesce(h.j->>'voucher_number', h.j->>'case_number', '') ref,
             coalesce(h.j->>'status', '') status,
             (select coalesce(sum(e.amount), 0) from assistance_ledger e where e.assistance_id = h.id and e.kind = 'due' and e.entry_date <= $1) due,
             (select coalesce(-sum(e.amount), 0) from assistance_ledger e where e.assistance_id = h.id and e.kind = 'payment' and e.entry_date <= $1) paid,
             (select coalesce(-sum(e.amount), 0) from assistance_ledger e where e.assistance_id = h.id and e.kind not in ('due', 'payment') and e.entry_date <= $1) adj,
             (select coalesce(sum(e.amount), 0) from assistance_ledger e where e.assistance_id = h.id and e.entry_date <= $1) bal,
             (select array_agg(e.entry_date) from assistance_ledger e where e.assistance_id = h.id and e.entry_date <= $1 and e.amount > 0) ds,
             (select array_agg(e.amount) from assistance_ledger e where e.assistance_id = h.id and e.entry_date <= $1 and e.amount > 0) am
      from h join report_leases() rl on rl.lease_id = h.lease_id),
    a as (select r.*, report_age(r.bal, r.ds, r.am, $1) ag from r)
    select coalesce(jsonb_agg(jsonb_build_object('agency', agency, 'unit', unit_label, 'tenants', tenants, 'reference', ref, 'status', status,
             'due', due, 'paid', paid, 'adjustments', adj, 'balance', bal, 'd0_30', (ag->>'d0_30')::numeric, 'd31_60', (ag->>'d31_60')::numeric,
             'd61_90', (ag->>'d61_90')::numeric, 'd90p', (ag->>'d90p')::numeric) order by agency, report_unit_sort(unit_number)), '[]'::jsonb),
           jsonb_build_object('due', coalesce(sum(due), 0), 'paid', coalesce(sum(paid), 0), 'adjustments', coalesce(sum(adj), 0), 'balance', coalesce(sum(bal), 0),
             'd0_30', coalesce(sum((ag->>'d0_30')::numeric), 0), 'd31_60', coalesce(sum((ag->>'d31_60')::numeric), 0),
             'd61_90', coalesce(sum((ag->>'d61_90')::numeric), 0), 'd90p', coalesce(sum((ag->>'d90p')::numeric), 0))
    from a $q$ into v_rows, v_tot using d;
  return jsonb_build_object('title', 'Housing assistance receivable', 'entity', '2nd Chance Housing Inc.', 'source', 'Housing assistance ledger (agency share of rent)',
    'period', jsonb_build_object('as_of', d), 'group_by', 'agency',
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'agency', 'label', 'Agency', 'type', 'text'), jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'),
      jsonb_build_object('key', 'tenants', 'label', 'Tenants', 'type', 'text'), jsonb_build_object('key', 'reference', 'label', 'Voucher / case #', 'type', 'text'),
      jsonb_build_object('key', 'status', 'label', 'Status', 'type', 'text'),
      jsonb_build_object('key', 'due', 'label', 'Agency share billed', 'type', 'money'), jsonb_build_object('key', 'paid', 'label', 'Received', 'type', 'money'),
      jsonb_build_object('key', 'adjustments', 'label', 'Adjust. / write-offs', 'type', 'money'), jsonb_build_object('key', 'balance', 'label', 'Owed by agency', 'type', 'money'),
      jsonb_build_object('key', 'd0_30', 'label', '0–30', 'type', 'money'), jsonb_build_object('key', 'd31_60', 'label', '31–60', 'type', 'money'),
      jsonb_build_object('key', 'd61_90', 'label', '61–90', 'type', 'money'), jsonb_build_object('key', 'd90p', 'label', 'Over 90', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('The agency''s share is kept off the tenant''s balance; this is what agencies owe 2nd Chance Housing. Totals are since each assistance record began, through the as-of date.'));
end $$;
revoke all on function report_assistance(date) from public, anon;
grant execute on function report_assistance(date) to authenticated;

-- ---------------------------------------------------------------------------
-- Owner: year-end summary of their association account(s), by GL account — charged and paid in a calendar year.
create or replace function owner_report_year(p_year int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); y0 date; y1 date; v_rows jsonb; v_tot jsonb; v_name text;
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  if p_year is null or p_year < 2000 or p_year > extract(year from current_date)::int then raise exception 'Choose a year.'; end if;
  y0 := make_date(p_year, 1, 1); y1 := make_date(p_year, 12, 31);
  select name into v_name from condo_owners where id = v_owner;
  with acc as (
    select a.id, u.unit_number from condo_ownerships s join condo_units u on u.id = s.unit_id
      join condo_ledger_accounts a on a.ownership_id = s.id and not a.excluded
     where s.owner_id = v_owner and s.is_current),
  e as (select acc.unit_number, x.* from condo_ledger_entries x join acc on acc.id = x.account_id where x.entry_date between y0 and y1),
  g as (select unit_number, gl_account gl,
          coalesce(sum(amount) filter (where kind in ('charge', 'late_fee')), 0) charged,
          coalesce(-sum(amount) filter (where kind = 'payment'), 0) paid,
          coalesce(-sum(amount) filter (where kind not in ('charge', 'late_fee', 'payment')), 0) credits
        from e group by unit_number, gl_account),
  b as (select acc.unit_number,
          (select coalesce(sum(x.amount), 0) from condo_ledger_entries x where x.account_id in (select id from acc a2 where a2.unit_number = acc.unit_number) and x.entry_date < y0) opening,
          (select coalesce(sum(x.amount), 0) from condo_ledger_entries x where x.account_id in (select id from acc a2 where a2.unit_number = acc.unit_number) and x.entry_date <= y1) closing
        from acc group by acc.unit_number)
  select coalesce((select jsonb_agg(jsonb_build_object('unit', 'Unit ' || g.unit_number, 'gl', case g.gl when 'Association Fee Income' then 'Association dues'
             when 'Late Fee Income' then 'Late fees' else g.gl end, 'charged', g.charged, 'paid', g.paid, 'credits', g.credits)
           order by report_unit_sort(g.unit_number), g.gl) from g), '[]'::jsonb),
         jsonb_build_object('charged', (select coalesce(sum(charged), 0) from g), 'paid', (select coalesce(sum(paid), 0) from g),
           'credits', (select coalesce(sum(credits), 0) from g),
           'opening', (select coalesce(sum(opening), 0) from b), 'closing', (select coalesce(sum(closing), 0) from b))
    into v_rows, v_tot;
  return jsonb_build_object('title', 'Year-end summary ' || p_year, 'entity', 'Royal Orleans Condominium – Addition One (ROCA1), managed by 2nd Chance Housing Inc.',
    'owner', v_name, 'source', 'Your association account ledger', 'period', jsonb_build_object('from', y0, 'to', y1), 'group_by', 'unit',
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'), jsonb_build_object('key', 'gl', 'label', 'Item', 'type', 'text'),
      jsonb_build_object('key', 'charged', 'label', 'Charged', 'type', 'money'), jsonb_build_object('key', 'paid', 'label', 'Paid', 'type', 'money'),
      jsonb_build_object('key', 'credits', 'label', 'Credits', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Balance on 1/1/' || p_year || ': ' || to_char((v_tot->>'opening')::numeric, 'FM$999,990.00') || '. Balance on 12/31/' || p_year || ': '
      || to_char((v_tot->>'closing')::numeric, 'FM$999,990.00') || '.',
      'Paid = payments posted in ' || p_year || ', split the way each payment was applied. Ask your tax preparer whether any of it is deductible.'));
end $$;
revoke all on function owner_report_year(int) from public, anon;
grant execute on function owner_report_year(int) to authenticated;

-- ---------------------------------------------------------------------------
-- Tenant: rent paid by calendar year, from their own lease ledgers.
create or replace function resident_rent_by_year()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_tot jsonb; v_name text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Sign-in required' using errcode = '42501'; end if;
  select string_agg(name, ', ') into v_name from tenants where id in (select resident_me());
  with ls as (select distinct lt.lease_id from lease_tenants lt where lt.tenant_id in (select resident_me())),
  e as (select rl.unit_label, rl.unit_number, extract(year from x.entry_date)::int y, x.*
          from lease_ledger_entries x join ls on ls.lease_id = x.lease_id join report_leases() rl on rl.lease_id = x.lease_id),
  g as (select unit_label, unit_number, y,
          coalesce(sum(amount) filter (where kind = 'charge' and gl_account in ('Rent Income', 'Rent Charge')), 0) rent_billed,
          coalesce(-sum(amount) filter (where kind = 'payment' and gl_account in ('Rent Income', 'Rent Charge')), 0) rent_paid,
          coalesce(-sum(amount) filter (where kind = 'in_kind'), 0) in_kind,
          coalesce(-sum(amount) filter (where kind = 'payment' and gl_account not in ('Rent Income', 'Rent Charge', 'Security Deposit Liability')), 0) other_paid,
          coalesce(-sum(amount) filter (where kind = 'payment' and gl_account = 'Security Deposit Liability'), 0) deposit_paid
        from e group by unit_label, unit_number, y)
  select coalesce(jsonb_agg(jsonb_build_object('year', y, 'unit', unit_label, 'rent_billed', rent_billed, 'rent_paid', rent_paid, 'in_kind', in_kind,
           'other_paid', other_paid, 'deposit_paid', deposit_paid) order by y desc, report_unit_sort(unit_number)), '[]'::jsonb),
         jsonb_build_object('rent_paid', coalesce(sum(rent_paid), 0), 'in_kind', coalesce(sum(in_kind), 0))
    into v_rows, v_tot from g;
  return jsonb_build_object('title', 'Rent paid by year', 'entity', '2nd Chance Housing Inc.', 'tenant', v_name, 'source', 'Your lease ledger',
    'period', jsonb_build_object('as_of', current_date),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'year', 'label', 'Year', 'type', 'int'), jsonb_build_object('key', 'unit', 'label', 'Unit', 'type', 'text'),
      jsonb_build_object('key', 'rent_billed', 'label', 'Rent billed', 'type', 'money'), jsonb_build_object('key', 'rent_paid', 'label', 'Rent paid', 'type', 'money'),
      jsonb_build_object('key', 'in_kind', 'label', 'Paid in work', 'type', 'money'), jsonb_build_object('key', 'other_paid', 'label', 'Fees & other paid', 'type', 'money'),
      jsonb_build_object('key', 'deposit_paid', 'label', 'Deposit paid', 'type', 'money')),
    'rows', v_rows, 'totals', v_tot,
    'notes', jsonb_build_array('Rent paid = payments applied to rent in that calendar year. Fees, late fees and the security deposit are shown separately and are not rent.'));
end $$;
revoke all on function resident_rent_by_year() from public, anon;
grant execute on function resident_rent_by_year() to authenticated;
