-- Retire the old system's names (Stephen, 10/11/2026: "drop all instances of the old system; only 2ndchinc remains").
-- Everything the old system left in columns, indexes, constraints and functions is renamed to a neutral name or dropped.
-- The dropped values were saved first to data/old-system-columns-backup-2026-10-11.json (local only).
-- Renamed: leases.legacy_lease_number -> account_number (it is the rent memo number the bank matcher uses),
-- leases.legacy_rental -> rental_label, letter_templates.legacy_id -> template_key, land_contract_ledger.legacy_gl -> gl_account,
-- condo_ledger_accounts.legacy_owner_label -> owner_label. Dropped: the old balances and running balances, ids and task numbers.
-- The site and the rent-cycle / resident-portal functions are deployed together with this migration.

drop view if exists lease_balances;
drop view if exists condo_ledger_balances;

alter table leases rename column legacy_lease_number to account_number;
alter table leases rename column legacy_rental to rental_label;
alter table letter_templates rename column legacy_id to template_key;
alter table land_contract_ledger rename column legacy_gl to gl_account;
alter table condo_ledger_accounts rename column legacy_owner_label to owner_label;
alter table letter_templates rename constraint letter_templates_legacy_id_key to letter_templates_template_key_key;
alter table condo_ledger_accounts rename constraint condo_ledger_accounts_unit_id_legacy_owner_label_source_key to condo_ledger_accounts_unit_id_owner_label_source_key;

alter table leases drop column if exists legacy_balance;
alter table lease_ledger_entries drop column if exists legacy_running_balance;
alter table condo_ledger_entries drop column if exists legacy_running_balance;
alter table condo_ledger_accounts drop column if exists legacy_balance;
alter table condo_ownerships drop column if exists legacy_account;
alter table condo_owners drop column if exists legacy_ids;
alter table land_contracts drop column if exists legacy_balance;
alter table ledger_corrections drop column if exists legacy_detail;
alter table maintenance_requests drop column if exists legacy_task_id;
alter table vendors drop column if exists legacy_id;
alter table announcements drop column if exists legacy_id;

-- Values that named the old system
alter table condo_ledger_entries drop constraint if exists condo_ledger_entries_origin_check;
update condo_ledger_entries set origin = 'imported' where origin = 'legacy';
alter table condo_ledger_entries add constraint condo_ledger_entries_origin_check check (origin in ('imported', 'billing', 'staff'));
alter table rental_applications drop constraint if exists rental_applications_source_check;
update rental_applications set source = 'imported' where source = 'legacy';
alter table rental_applications add constraint rental_applications_source_check check (source in ('site', 'imported'));

update condo_owners set staff_notes = replace(replace(replace(staff_notes, 'Legacy note (unit 5 record):', 'Imported note (unit 5 record):'), 'Legacy note:', 'Imported note:'), 'Legacy mislabeled', 'The old system mislabeled') where staff_notes ilike '%legacy%';
update condo_ledger_accounts set correction_note = replace(replace(correction_note, 'Legacy mislabeled', 'The old system mislabeled'), 'Legacy billed', 'The old system billed') where correction_note ilike '%legacy%';
update roca_resolutions set origin_note = replace(origin_note, 'through Legacy e-signature', 'through the former system''s e-signature') where origin_note ilike '%legacy%';

create view condo_ledger_balances with (security_invoker = true) as
select a.id AS account_id,
    u.unit_number,
    a.owner_label,
    a.excluded,
    (COALESCE(sum(e.amount), (0)::numeric))::numeric(12,2) AS balance,
    min(e.entry_date) AS first_entry,
    max(e.entry_date) AS last_entry,
    count(e.id) AS entries
   FROM ((condo_ledger_accounts a
     JOIN condo_units u ON ((u.id = a.unit_id)))
     LEFT JOIN condo_ledger_entries e ON ((e.account_id = a.id)))
  GROUP BY a.id, u.unit_number;
grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on condo_ledger_balances to service_role;

create view lease_balances with (security_invoker = true) as
select l.id AS lease_id,
    (COALESCE(sum(e.amount), (0)::numeric))::numeric(12,2) AS balance,
    count(e.id) AS entries,
    min(e.entry_date) AS first_entry,
    max(e.entry_date) AS last_entry
   FROM (leases l
     LEFT JOIN lease_ledger_entries e ON ((e.lease_id = l.id)))
  GROUP BY l.id;
grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on lease_balances to service_role;

CREATE OR REPLACE FUNCTION public.bank_candidates(p_receipt uuid)
 RETURNS TABLE(target_kind text, target_id uuid, label text, why text, rank integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      select l.id, l.account_number num, l.tenants_label, coalesce(ru.unit_number, '') unit, l.rent
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
$function$;

CREATE OR REPLACE FUNCTION public.billing_post_month(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    insert into land_contract_ledger (contract_id, entry_date, kind, gl_account, raw_type, description, amount, source)
    values (r.id, m, 'installment_due', 'Rent Income', 'Charge', 'Installment', r.monthly_payment, 'billing');
    n_lc := n_lc + 1;
  end loop;
  return jsonb_build_object('month', m, 'rent_charges', n_rent, 'work_credits', n_credit, 'land_contract_installments', n_lc);
end;
$function$;

CREATE OR REPLACE FUNCTION public.condo_account_json(p_account uuid, p_staff boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'account_id', a.id,
    'owner', coalesce((select o.name from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.id = a.ownership_id), a.owner_label),
    'is_current_owner', coalesce((select s.is_current from condo_ownerships s where s.id = a.ownership_id), false),
    'owner_label', a.owner_label, 'correction_note', a.correction_note,
    'excluded', a.excluded, 'excluded_reason', a.excluded_reason, 'billing_account', a.billing_account,
    'balance', condo_account_balance(a.id),
    'entries', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'date', x.entry_date, 'gl', x.gl_account, 'kind', x.kind, 'type', x.raw_type, 'description', x.description,
        'method', x.method, 'check_number', x.check_number,
        'amount', x.amount, 'balance', x.running, 'origin', x.origin, 'note', x.correction_note,
        'entered_by', case when p_staff then x.entered_by end, 'reverses', x.reverses_entry_id,
        'reversed', exists (select 1 from condo_ledger_entries r where r.reverses_entry_id = x.id))
        order by x.entry_date, x.id), '[]'::jsonb)
      from (select e.*, sum(e.amount) over (order by e.entry_date, e.id) as running
            from condo_ledger_entries e where e.account_id = a.id) x))
  from condo_ledger_accounts a where a.id = p_account;
$function$;

CREATE OR REPLACE FUNCTION public.condo_billing_account(p_unit uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_own condo_ownerships; v_acct uuid; v_name text;
begin
  select * into v_own from condo_ownerships where unit_id = p_unit and is_current order by start_date desc nulls last limit 1;
  if v_own.id is null then return null; end if;
  select id into v_acct from condo_ledger_accounts where unit_id = p_unit and billing_account and ownership_id = v_own.id;
  if v_acct is not null then return v_acct; end if;
  update condo_ledger_accounts set billing_account = false where unit_id = p_unit and billing_account;
  select id into v_acct from condo_ledger_accounts where unit_id = p_unit and ownership_id = v_own.id and not excluded
    order by imported_at desc limit 1;
  if v_acct is null then
    select name into v_name from condo_owners where id = v_own.owner_id;
    insert into condo_ledger_accounts (unit_id, ownership_id, owner_label, source, correction_note)
    values (p_unit, v_own.id, v_name, '2ndchinc', 'Opened by this system when the ownership began.')
    returning id into v_acct;
  end if;
  update condo_ledger_accounts set billing_account = true where id = v_acct;
  return v_acct;
end;
$function$;

CREATE OR REPLACE FUNCTION public.condo_post_late_fees(p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d int := extract(day from p_day);
  flat_day int := condo_setting('dues_late_flat_day', '10')::int;
  pct_day int := condo_setting('dues_late_pct_day', '11')::int;
  flat numeric := condo_setting('dues_late_flat', '25')::numeric;
  pct numeric := condo_setting('dues_late_pct', '1.15')::numeric;
  pct_base text := condo_setting('dues_late_pct_base', 'balance');
  v_annual numeric := condo_setting('dues_interest_annual_pct', '4.5')::numeric;
  v_eff date := condo_setting('dues_interest_effective', '2026-10-08')::date;
  r record; v_hold boolean; v_held numeric; v_month date := date_trunc('month', p_day)::date; v_base numeric; v_fee numeric; v_credits numeric; n_flat int := 0; n_pct int := 0;
begin
  -- Catch-up: every day from the flat-fee day to month end, each fee at most once per account per month, so a fee held back
  -- while a payment was processing posts the day the payment fails.
  if d < flat_day then return jsonb_build_object('day', p_day, 'late_fees', 0); end if;
  -- Before the effective date: the old percentage rule, so history is never recomputed differently.
  if p_day < v_eff and pct_base = 'assessments_simple' then pct_base := 'balance'; end if;
  for r in select a.id, condo_account_balance(a.id, p_day) as bal from condo_ledger_accounts a where a.billing_account and not a.excluded
  loop
    -- A payment still processing (bank payment in flight, or a recent "I've paid" report) holds the fee back: the owner paid on time.
    v_held := coalesce((select sum(s.amount) from stripe_payments s where s.condo_account_id = r.id and s.status = 'processing'), 0)
            + coalesce((select sum(pr.amount) from payment_reports pr where pr.condo_account_id = r.id and pr.status = 'pending' and payment_report_fresh(pr, p_day)), 0);
    -- Unit whose tenant pays rent into ROCA1's account: that tenant's pending rent also holds the fee (the account is paused until it clears).
    v_held := v_held + coalesce((select roca_unit_pending_rent(u2.unit_number, p_day) from condo_ledger_accounts a2 join condo_units u2 on u2.id = a2.unit_id where a2.id = r.id), 0);
    v_hold := exists (select 1 from condo_late_holds where account_id = r.id and month = v_month);
    if r.bal <= 0 then
      if v_hold then delete from condo_late_holds where account_id = r.id and month = v_month; end if;   -- the pending payment cleared: nothing owed
      continue;
    end if;
    continue when not (d = flat_day or d = pct_day or v_hold);
    if r.bal - v_held <= 0 then   -- still pending: hold, and remember it so the fee follows if the payment fails
      insert into condo_late_holds (account_id, month) values (r.id, v_month) on conflict do nothing;
      continue;
    end if;
    if (d = flat_day or v_hold) and flat > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                  and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description = 'Late fee') then
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
      values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee', flat, 'billing', 'monthly billing');
      n_flat := n_flat + 1;
    end if;
    continue when not (d = pct_day or (v_hold and d >= pct_day));
    if pct_base = 'assessments_simple' then
      -- Simple interest on unpaid assessments that were due before today; all payments and credits applied to them first.
      continue when v_annual <= 0 or exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Interest Income'
                                                and entry_date >= v_month and entry_date <= p_day and origin = 'billing');
      select coalesce(sum(amount) filter (where amount > 0 and gl_account in ('Association Fee Income', 'Association Dues', 'Special Assessment') and entry_date < p_day), 0),
             coalesce(-sum(amount) filter (where amount < 0), 0)
        into v_base, v_credits
        from condo_ledger_entries where account_id = r.id and entry_date <= p_day;
      v_base := greatest(v_base - v_credits, 0);
      v_fee := round(v_base * v_annual / 100 / 12, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
        values (r.id, 'Interest Income', p_day, 'charge', 'Charge',
                'Interest ' || v_annual || '% a year on unpaid assessments of ' || to_char(v_base, 'FM$999,999,990.00') || ' (one month)', v_fee, 'billing', 'monthly billing',
                'By-Laws 2020 §1500(3) rate; Wis. Stat. § 703.165. Simple interest, not charged on late fees, fines or earlier interest.');
        n_pct := n_pct + 1;
      end if;
    elsif pct > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                    and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description like 'Late fee %') then
      v_base := case when pct_base = 'charges'
                     then (select coalesce(sum(amount), 0) from condo_ledger_entries where account_id = r.id and entry_date <= p_day
                           and not (gl_account = 'Late Fee Income' and amount > 0))
                     else condo_account_balance(r.id, p_day) end;
      v_fee := round(v_base * pct / 100, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
        values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee ' || pct || '% of ' || to_char(v_base, 'FM$999,999,990.00'), v_fee, 'billing', 'monthly billing');
        n_pct := n_pct + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('day', p_day, 'flat_fees', n_flat, 'percent_fees', n_pct, 'rule', pct_base);
end;
$function$;

CREATE OR REPLACE FUNCTION public.condo_staff_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'unit_number', u.unit_number, 'address', u.address, 'pin', u.pin, 'occupancy', u.occupancy,
        'current', (select jsonb_agg(jsonb_build_object('owner_id', s.owner_id, 'owner_name', o.name, 'since', s.start_date,
                      'board_position', s.board_position, 'fee', s.fee, 'fee_frequency', s.fee_frequency))
                    from condo_ownerships s join condo_owners o on o.id = s.owner_id
                    where s.unit_id = u.id and s.is_current))
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int) from condo_units u), '[]'::jsonb),
    'owners', coalesce((select jsonb_agg(to_jsonb(o) || jsonb_build_object(
        'units', condo_unit_label(o.id),
        'is_current', exists (select 1 from condo_ownerships s where s.owner_id = o.id and s.is_current))
        order by o.name) from condo_owners o), '[]'::jsonb),
    'updates', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc)
        from (select * from condo_profile_updates order by created_at desc limit 50) p), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.inspection_appointment_create(p_property text, p_unit text, p_purpose text, p_start timestamp with time zone, p_end timestamp with time zone, p_inspector text, p_note text, p_notice boolean, p_consent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a inspection_appointments; v_lease uuid; v_basis text; v_tpl uuid; v_html text; t record; v_insp text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if inspection_rental_unit(p_property, p_unit) is null then raise exception 'Unit % isn''t on file.', p_unit; end if;
  if coalesce(p_purpose, 'routine') not in ('routine', 'annual', 'pre_move_out', 'follow_up', 'complaint', 'other') then raise exception 'Unknown inspection purpose'; end if;
  if p_start is null or p_end is null or p_end <= p_start then raise exception 'Enter the date and a time window (end after start).'; end if;
  if p_start < now() then raise exception 'The appointment can''t start in the past.'; end if;
  if exists (select 1 from inspection_appointments x where x.property_id = p_property and x.unit = p_unit and x.status = 'scheduled'
             and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_start, p_end)) then raise exception 'This unit already has an inspection booked at that time.'; end if;
  v_insp := lower(nullif(trim(coalesce(p_inspector, '')), ''));
  if v_insp is null then select inspector_email into v_insp from inspection_schedules where property_id = p_property and unit = p_unit; end if;
  v_lease := inspection_active_lease(p_property, p_unit);
  if v_lease is null then v_basis := 'vacant';
  elsif coalesce(p_notice, true) then
    if p_start < now() + interval '12 hours' then raise exception 'With a 12-hour notice the inspection must start at least 12 hours from now (after %).',
      to_char((now() + interval '12 hours') at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM'); end if;
    v_basis := 'notice';
  else
    if length(trim(coalesce(p_consent, ''))) < 5 then raise exception 'Without a notice, say how and when the tenant agreed to this entry (e.g. "Agreed by phone 10/7").'; end if;
    v_basis := 'consent';
  end if;
  insert into inspection_appointments (property_id, unit, lease_id, purpose, starts_at, ends_at, inspector_email, entry_basis, consent_note, note, created_by)
  values (p_property, p_unit, v_lease, coalesce(p_purpose, 'routine'), p_start, p_end, v_insp, v_basis,
          case when v_basis = 'consent' then left(trim(p_consent), 300) end, left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()))
  returning * into a;
  if v_basis = 'notice' then
    select id into v_tpl from letter_templates where template_key = '2c-12-hour-inspection';
    v_html := letter_render_ctx('2c-12-hour-inspection', v_lease, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', lower(inspection_purpose_label(a.purpose)) || ' of the unit' || coalesce(' (' || a.note || ')', '')));
  elsif v_basis = 'consent' then
    for t in select y.name, y.email from lease_tenants lt join tenants y on y.id = lt.tenant_id where lt.lease_id = v_lease and y.email is not null loop
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Unit inspection: ' || to_char(p_start at time zone 'America/Chicago', 'FMMM/FMDD'),
        tenant_email_wrap(split_part(t.name, ' ', 1), '<p>As you agreed, we will do a <b>' || lower(inspection_purpose_label(a.purpose)) || '</b> of your unit on <b>'
          || inspection_window_text(p_start, p_end) || '</b>.</p>' || coalesce('<p>' || repair_esc(a.note) || '</p>', '')
          || '<p>Questions or a better time? Call ' || coalesce((select value from portal_settings where key = 'org_phone'), 'the office') || '.</p>'), 'inspection');
    end loop;
    update inspection_appointments set notice_sent_at = now() where id = a.id returning * into a;
  end if;
  if v_insp is not null and v_insp <> lower(auth.email()) then
    insert into email_outbox (to_email, subject, html, kind) values (v_insp, 'Inspection booked — Unit ' || a.unit || ', ' || to_char(p_start at time zone 'America/Chicago', 'FMMM/FMDD'),
      '<p>You are booked for a <b>' || lower(inspection_purpose_label(a.purpose)) || '</b> of <b>Unit ' || repair_esc(a.unit) || '</b> on <b>' || inspection_window_text(p_start, p_end) || '</b>.</p>'
      || case v_basis when 'notice' then '<p>The tenant gets the 12-hour notice to enter.</p>' when 'consent' then '<p>The tenant agreed to the entry: ' || repair_esc(a.consent_note) || '</p>' else '<p>The unit is vacant.</p>' end
      || coalesce('<p>Note: ' || repair_esc(a.note) || '</p>', '')
      || '<p>Start the inspection: https://2ndchinc.org/inspections/unit/?p=' || a.property_id || '&u=' || a.unit || '&purpose=' || a.purpose || '&appt=' || a.id || '</p>', 'inspection');
  end if;
  return inspection_appt_row(a) || jsonb_build_object('notice', v_basis = 'notice', 'template_id', v_tpl, 'html', v_html,
    'notice_subject', 'Notice To Enter — ' || inspection_purpose_label(a.purpose));
end;
$function$;

CREATE OR REPLACE FUNCTION public.inspection_appointment_notice(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a inspection_appointments;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into a from inspection_appointments where id = p_id;
  if a.id is null or a.status <> 'scheduled' or a.entry_basis <> 'notice' then raise exception 'Only a booked appointment that needs a notice can get one.'; end if;
  if a.notice_id is not null then raise exception 'The notice for this appointment was already sent.'; end if;
  if a.starts_at < now() + interval '12 hours' then raise exception 'Too late for a 12-hour notice: cancel this appointment and book a new time (or record the tenant''s agreement).'; end if;
  return jsonb_build_object('id', a.id, 'lease_id', a.lease_id, 'template_id', (select id from letter_templates where template_key = '2c-12-hour-inspection'),
    'notice_subject', 'Notice To Enter — ' || inspection_purpose_label(a.purpose),
    'html', letter_render_ctx('2c-12-hour-inspection', a.lease_id, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(a.starts_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(a.starts_at at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(a.ends_at at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', lower(inspection_purpose_label(a.purpose)) || ' of the unit' || coalesce(' (' || a.note || ')', ''))));
end;
$function$;

CREATE OR REPLACE FUNCTION public.land_contract_interest(p_contract uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c land_contracts;
  bal numeric; unpaid numeric := 0; last date;
  r record; i numeric; amt numeric;
  ints jsonb := '{}'::jsonb; prins jsonb := '{}'::jsonb; y text;
  y0 int; y1 int; yrs jsonb;
begin
  select * into c from land_contracts where id = p_contract;
  if not found or c.contract_date is null or c.interest_rate is null then return null; end if;
  bal := coalesce(c.purchase_price, 0) - coalesce(c.down_payment, 0);
  last := c.contract_date;
  for r in select entry_date, -amount as amt from land_contract_ledger
           where contract_id = p_contract and kind = 'payment' and gl_account = 'Rent Income'
             and entry_date >= c.contract_date and entry_date <= p_as_of
           order by entry_date, id loop
    amt := r.amt;
    if amt <= 0 then continue; end if;
    unpaid := unpaid + bal * c.interest_rate * (r.entry_date - last) / 365;
    last := r.entry_date;
    i := least(unpaid, amt);
    unpaid := unpaid - i;
    bal := bal - (amt - i);
    y := extract(year from r.entry_date)::int::text;
    ints := jsonb_set(ints, array[y], to_jsonb(coalesce((ints ->> y)::numeric, 0) + i));
    prins := jsonb_set(prins, array[y], to_jsonb(coalesce((prins ->> y)::numeric, 0) + (amt - i)));
  end loop;
  unpaid := unpaid + bal * c.interest_rate * (p_as_of - last) / 365;
  y0 := extract(year from c.contract_date)::int; y1 := extract(year from p_as_of)::int;
  select coalesce(jsonb_agg(jsonb_build_object('year', g, 'interest', round(coalesce((ints ->> g::text)::numeric, 0), 2),
      'principal', round(coalesce((prins ->> g::text)::numeric, 0), 2),
      'paid', round(coalesce((ints ->> g::text)::numeric, 0) + coalesce((prins ->> g::text)::numeric, 0), 2),
      'complete', g < y1) order by g), '[]'::jsonb)
    into yrs from generate_series(y0, y1) g;
  return jsonb_build_object('years', yrs, 'principal_balance', round(bal, 2), 'accrued_interest', round(unpaid, 2), 'as_of', p_as_of);
end;
$function$;

CREATE OR REPLACE FUNCTION public.land_contracts_staff_ledger(p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('date', entry_date, 'kind', kind, 'gl', gl_account, 'type', raw_type,
      'description', description, 'amount', amount, 'principal', principal, 'interest', interest) order by entry_date, id)
    from land_contract_ledger where contract_id = p_contract_id), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lc_unpaid(p_as_of date)
 RETURNS TABLE(contract_id uuid, property text, past_due_installments numeric, late_fees numeric, total numeric, buyers jsonb, oldest_due date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with x as (
    select c.id, p.street, c.monthly_payment,
           greatest(coalesce(sum(e.amount) filter (where coalesce(e.gl_account, 'Rent Income') = 'Rent Income' and e.kind <> 'rent_due'
             and e.entry_date >= coalesce(c.first_payment_date, '1900-01-01') and e.entry_date <= p_as_of), 0), 0) as inst,
           greatest(coalesce(sum(e.amount) filter (where e.gl_account = 'Late Fee Income' and e.entry_date <= p_as_of), 0), 0) as fees
    from land_contracts c join rental_properties p on p.id = c.property_id left join land_contract_ledger e on e.contract_id = c.id
    where c.status = 'active' group by c.id, p.street, c.monthly_payment)
  select x.id, x.street, x.inst, x.fees, x.inst + x.fees,
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from land_contract_buyers b join tenants t on t.id = b.tenant_id where b.contract_id = x.id),
         (date_trunc('month', p_as_of) - make_interval(months => greatest(ceil(x.inst / nullif(x.monthly_payment, 0))::int - 1, 0)))::date
  from x where x.inst > 0;
$function$;

CREATE OR REPLACE FUNCTION public.lease_assign_account_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text;
begin
  if coalesce(trim(new.account_number), '') = '' then
    loop
      v := nextval('lease_account_seq')::text;
      exit when not exists (select 1 from leases where account_number = v);
    end loop;
    new.account_number := v;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lease_from_signing(p_doc uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  insert into leases (unit_id, rental_label, tenants_label, start_date, end_date, lease_type, status, rent, rent_start, deposit_held,
                      signing_doc_id, application_id, correction_note)
  values (v_unit, '2ndchinc.org lease', v_names, v_start, case when v_type = 'fixed' then v_end end, v_type,
          case when v_start > current_date then 'future' else 'active' end, v_rent, v_start, 0, d.id, d.application_id,
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
$function$;

CREATE OR REPLACE FUNCTION public.letter_queue_to_tenants(p_template text, p_lease uuid, p_kind text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; n int := 0; v_subject text;
begin
  select subject into v_subject from letter_templates where template_key = p_template;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = p_lease and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, v_subject, letter_render(p_template, p_lease, split_part(t.name, ' ', 1)), p_kind);
    n := n + 1;
  end loop;
  return n;
end;
$function$;

CREATE OR REPLACE FUNCTION public.letter_render_ctx(p_template text, p_lease uuid, p_extra jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_html text;
begin
  select html into v_html from letter_templates where template_key = p_template;
  if v_html is null then raise exception 'Letter % not found', p_template; end if;
  return letter_fill(v_html, p_lease, p_extra);
end;
$function$;

CREATE OR REPLACE FUNCTION public.letter_templates_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'key', template_key, 'built', built, 'recipient', recipient, 'name', name, 'subject', subject,
      'description', description, 'html', html, 'fields', fields) order by recipient, built desc, name) from letter_templates where active), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.maintenance_staff_schedule(p_id uuid, p_vendor uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_purpose text, p_notice boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r maintenance_requests; v_when text; v_html text; v_tpl uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status in ('completed', 'closed') then raise exception 'This request is already done.'; end if;
  if p_start is null or p_end is null or p_end <= p_start then raise exception 'Enter the visit date and a time window (end after start).'; end if;
  if length(trim(coalesce(p_purpose, ''))) < 3 then raise exception 'Say what the visit is for (it goes on the notice).'; end if;
  if p_notice then
    if r.lease_id is null then raise exception 'This request has no lease, so a notice can''t be made. Contact the tenant directly.'; end if;
    if p_start < now() + interval '12 hours' then raise exception 'With a 12-hour notice the visit must start at least 12 hours from now (after %).',
      to_char((now() + interval '12 hours') at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM'); end if;
  elsif r.entry_permission <> 'yes' then
    raise exception 'The tenant did not give permission to enter, so send the 12-hour notice.';
  end if;
  v_when := repair_window_text(p_start, p_end);
  update maintenance_requests set status = 'scheduled', vendor_id = coalesce(p_vendor, vendor_id), scheduled_start = p_start, scheduled_end = p_end,
    entry_purpose = left(trim(p_purpose), 300), updated_at = now() where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, status, note)
  values (p_id, auth.email(), 'scheduled', 'Visit scheduled: ' || v_when || coalesce(' (' || (select name from vendors where id = coalesce(p_vendor, r.vendor_id)) || ')', '') ||
          case when p_notice then '. 12-hour notice to enter sent.' else '. You gave permission to enter.' end);
  if p_notice then
    select id into v_tpl from letter_templates where template_key = '2c-12-hour-repair';
    v_html := letter_render_ctx('2c-12-hour-repair', r.lease_id, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', left(trim(p_purpose), 300), 'Request_Number', r.number::text));
  else
    perform repair_email_tenants(p_id, 'Repair request #' || r.number || ': Scheduled',
      '<p>Your repair request <b>' || repair_esc(r.subject) || '</b> is scheduled for <b>' || v_when || '</b>. You gave us permission to enter if you''re not home.</p>');
  end if;
  return jsonb_build_object('ok', true, 'lease_id', r.lease_id, 'template_id', v_tpl, 'subject', 'Notice To Enter — repair request #' || r.number, 'html', v_html);
end;
$function$;

CREATE OR REPLACE FUNCTION public.moveout_staff_deposit(p_id uuid, p_deductions jsonb, p_letter text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m move_outs; l leases; d jsonb; r record; s jsonb;
  v_ded numeric := 0; v_unpaid numeric; v_dep numeric; v_net numeric; v_items text := ''; v_acct text := '';
  v_end date; v_days int := 0; v_daily numeric := 0; v_double numeric := 0; v_already numeric := 0; v_claim numeric := 0; v_total numeric;
  v_pay_by date; v_limit numeric; v_forum text; v_tpl text; v_out text; v_email_out text; v_hold text := ''; v_hold_email text := '';
  v_sum text; v_extra jsonb; v_acting text; v_html text; v_email text; v_subject text;
  money_ text := 'FM$999,990.00';
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(p_letter, '') not in ('court', 'double_rent', 'absorbed') then raise exception 'Choose which deposit statement to send.'; end if;
  select * into m from move_outs where id = p_id and status in ('vacated', 'inspected');
  if m.id is null then raise exception 'Finish the inspection first (or the deposit statement was already sent).'; end if;
  if m.forwarding_address is null then raise exception 'There is no forwarding address. Ask the tenant to add it in the portal, or enter their last known address.'; end if;
  select * into l from leases where id = m.lease_id;
  select jsonb_object_agg(key, value) into s from portal_settings;

  -- Deductions entered on the inspection.
  for d in select * from jsonb_array_elements(coalesce(p_deductions, '[]'::jsonb)) loop
    if length(trim(coalesce(d->>'desc', ''))) < 3 or (d->>'amount') is null then raise exception 'Every line needs a description and an amount.'; end if;
    if coalesce(d->>'category', 'damage') not in ('damage', 'cleaning', 'other', 'credit') then raise exception 'Unknown category.'; end if;
    v_ded := v_ded + (d->>'amount')::numeric;
    v_items := v_items || '<li>' || repair_esc(trim(d->>'desc')) || ': ' || case when (d->>'amount')::numeric < 0
      then 'credit to you ' || to_char(-(d->>'amount')::numeric, money_) else to_char((d->>'amount')::numeric, money_) end || '</li>';
  end loop;
  -- Unpaid rent and charges, itemized by account (each claim described, ATCP 134.06(4)(a)).
  -- Legal charges are left off: a lease can't make a tenant pay attorney fees (§ 704.44(4m)); Stephen 10/4/2026.
  for r in select gl_account, sum(amount) amt from lease_ledger_entries where lease_id = l.id and gl_account <> 'Legal' group by gl_account having sum(amount) <> 0
           order by gl_account <> 'Rent Income', gl_account loop
    v_acct := v_acct || '<li>' || repair_esc(deposit_gl_label(r.gl_account)) || ': ' || case when r.amt < 0 then 'credit to you ' || to_char(-r.amt, money_) else to_char(r.amt, money_) end || '</li>';
  end loop;
  v_dep := coalesce(l.deposit_held, 0);
  v_unpaid := greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id and gl_account <> 'Legal'), 0);
  v_net := v_dep - v_unpaid - v_ded;

  -- Holding over (§ 704.27): twice the daily rental value for each day in
  -- possession after the tenancy ended. Rent already charged for those days is
  -- in the balance above, so only the second half is added.
  v_end := coalesce(m.move_out_date, l.end_date);
  if v_end is not null and m.surrendered_on > v_end then v_days := m.surrendered_on - v_end; end if;
  if p_letter = 'double_rent' then
    if v_days <= 0 then raise exception 'The tenant did not stay past the end of the tenancy (%), so there is no double rent to claim. Choose another statement.', coalesce(to_char(v_end, 'FMMM/FMDD/YYYY'), 'no end date'); end if;
    v_daily := round(coalesce(l.rent, 0) * 12 / 365, 2);
    v_double := v_daily * 2 * v_days;
    if exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge' and e.gl_account in ('Rent Income', 'Rent Charge') and e.entry_date > v_end) then
      v_already := v_daily * v_days;
    end if;
    v_claim := v_double - v_already;
    v_hold := 'Your tenancy ended on ' || to_char(v_end, 'FMMonth FMDD, YYYY') || ', but you stayed in the unit without our consent until ' ||
      to_char(m.surrendered_on, 'FMMonth FMDD, YYYY') || ' (' || v_days || ' day' || case when v_days = 1 then '' else 's' end || '). Under Wis. Stat. § 704.27, ' ||
      'a tenant who stays after the tenancy ends owes at least twice the rental value for each of those days. Your rent of ' || to_char(l.rent, money_) ||
      ' a month is ' || to_char(v_daily, money_) || ' a day (rent × 12 ÷ 365). Twice that for ' || v_days || ' day' || case when v_days = 1 then '' else 's' end ||
      ' is <b>' || to_char(v_double, money_) || '</b>.' ||
      case when v_already > 0 then ' Rent of ' || to_char(v_already, money_) || ' for those days is already in the balance above, so the additional amount claimed is <b>' || to_char(v_claim, money_) || '</b>.' else '' end ||
      ' This amount is not taken from your security deposit; it is claimed in addition to the statement above.';
    v_hold_email := 'Because you stayed ' || v_days || ' day' || case when v_days = 1 then '' else 's' end || ' after your tenancy ended, the statement also claims double rent under Wis. Stat. § 704.27: <b>' ||
      to_char(v_claim, money_) || '</b>.';
  end if;

  v_total := greatest(-v_net, 0) + v_claim;
  v_pay_by := current_date + coalesce((s->>'deposit_balance_pay_days')::int, 14);
  v_limit := case when current_date >= date '2027-01-01' then 15000 else 10000 end;   -- 799.01(1)(d), 2025 Wis. Act 105
  v_forum := case when v_total <= v_limit then 'a small claims action in Milwaukee County Circuit Court' else 'an action in Milwaukee County Circuit Court' end;

  v_out := case
    when p_letter = 'absorbed' and v_net < 0 then
      'The amounts above are more than your security deposit by ' || to_char(-v_net, money_) || '. ' ||
      '2nd Chance Housing Inc. is a nonprofit organization. Under our policy for tenants who qualify as indigent, this balance is absorbed. ' ||
      'You owe nothing further. We are not seeking damages or double rent.'
    when v_total <= 0 then
      case when v_net > 0 then 'A refund of <b>' || to_char(v_net, money_) || '</b> is being mailed to the address above. You owe nothing further.'
           else 'Your security deposit covered the amounts above in full. Nothing is owed by either party.' end || ' We are not seeking damages or double rent.'
    else
      case when v_net > 0 then 'A refund of <b>' || to_char(v_net, money_) || '</b> is being mailed to the address above. '
           when v_net < 0 then 'The amounts above are more than your security deposit. A balance of <b>' || to_char(-v_net, money_) || '</b> remains. ' else '' end ||
      case when p_letter = 'double_rent' then 'With the double rent claimed above, the total you owe is <b>' || to_char(v_total, money_) || '</b>. '
           else 'The total you owe is <b>' || to_char(v_total, money_) || '</b>. ' end ||
      'Please pay it by <b>' || to_char(v_pay_by, 'FMMonth FMDD, YYYY') || '</b> in your resident portal, or call us to arrange payment. ' ||
      'If it is not paid by then, [[ACTING]] will file ' || v_forum || ' asking the judge for a judgment for the total owed, plus the court costs allowed by law.' ||
      case when p_letter = 'court' then ' We are not claiming double rent.' else '' end
  end;
  v_email_out := case
    when p_letter = 'absorbed' and v_net < 0 then 'Under our nonprofit policy, the remaining balance of ' || to_char(-v_net, money_) || ' is absorbed. You owe nothing further.'
    when v_total <= 0 then case when v_net > 0 then 'A refund of ' || to_char(v_net, money_) || ' is being mailed to you. You owe nothing further.' else 'Your deposit covered everything. Nothing is owed by either party.' end
    else case when v_net > 0 then 'A refund of ' || to_char(v_net, money_) || ' is being mailed to you. ' else '' end ||
      'The total you owe is <b>' || to_char(v_total, money_) || '</b>, due by <b>' || to_char(v_pay_by, 'FMMonth FMDD, YYYY') ||
      '</b>. You can pay in your resident portal. If it is not paid by then, [[ACTING]] will ask the court for a judgment for the total owed.'
  end;

  v_sum := '<p>Security deposit held: <b>' || to_char(v_dep, money_) || '</b><br>Unpaid rent and charges: <b>' || to_char(v_unpaid, money_) ||
    '</b><br>Damage and cleaning: <b>' || to_char(v_ded, money_) || '</b><br>' ||
    case when v_net >= 0 then 'Returned to you: <b>' || to_char(v_net, money_) || '</b>' else 'Balance after the deposit: <b>' || to_char(-v_net, money_) || '</b>' end || '</p>';

  update move_outs set deductions = coalesce(p_deductions, '[]'::jsonb), deposit_held = v_dep, unpaid_balance = v_unpaid,
    refund_amount = greatest(v_net, 0), balance_due = case when p_letter = 'absorbed' then greatest(-v_net, 0) else v_total end,
    absorb_balance = p_letter = 'absorbed', deposit_letter = p_letter, holdover_days = nullif(v_days, 0), holdover_claim = nullif(v_claim, 0),
    pay_by = case when p_letter <> 'absorbed' and v_total > 0 then v_pay_by end where id = p_id;

  v_tpl := case p_letter when 'court' then '2c-deposit-court' when 'double_rent' then '2c-deposit-double-rent' else '2c-deposit-absorbed' end;
  v_extra := jsonb_build_object('_keep_signature', true, 'Forwarding_Address', m.forwarding_address,
    'Surrender_Date', to_char(m.surrendered_on, 'FMMonth FMDD, YYYY'), 'Tenancy_End_Date', coalesce(to_char(least(v_end, m.surrendered_on), 'FMMonth FMDD, YYYY'), to_char(m.surrendered_on, 'FMMonth FMDD, YYYY')),
    'Outcome_Text', '[[OUTCOME]]', 'Holdover_Text', '[[HOLDOVER]]', 'Itemization', '[[ITEMS]]',
    'Email_Summary', '[[SUMMARY]]', 'Email_Outcome', '[[EMAIL_OUTCOME]]', 'Holdover_Email', '[[HOLDOVER_EMAIL]]', 'Tenant_First_Name', '[[FIRST]]');
  v_acting := notice_context_body(l.id, null)->>'Landlord_Acting';
  v_out := replace(v_out, '[[ACTING]]', repair_esc(v_acting));
  v_email_out := replace(v_email_out, '[[ACTING]]', repair_esc(replace(v_acting, ', for the unit owner,', '')));
  v_html := letter_render_ctx(v_tpl, l.id, v_extra);
  -- These parts are built here from escaped values, so they go in unescaped.
  v_html := replace(replace(replace(v_html, '[[OUTCOME]]', v_out), '[[HOLDOVER]]', v_hold), '[[ITEMS]]',
    '<p><b>Security deposit held: ' || to_char(v_dep, money_) || '</b></p>' ||
    '<p><b>Unpaid rent and charges on your account: ' || to_char(v_unpaid, money_) || '</b></p>' ||
    case when v_acct <> '' then '<ul>' || v_acct || '</ul>' else '' end ||
    case when v_items <> '' then '<p><b>Damage, cleaning and other deductions:</b></p><ul>' || v_items || '</ul>' else '<p>No deductions for damage or cleaning.</p>' end ||
    '<p><b>' || case when v_net >= 0 then 'Amount returned to you: ' || to_char(v_net, money_) else 'Balance after the deposit: ' || to_char(-v_net, money_) end || '</b></p>');
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where template_key = v_tpl;
  v_email := replace(replace(replace(v_email, '[[SUMMARY]]', v_sum), '[[EMAIL_OUTCOME]]', v_email_out), '[[HOLDOVER_EMAIL]]', v_hold_email);

  return jsonb_build_object('ok', true, 'lease_id', l.id, 'deposit_held', v_dep, 'unpaid_balance', v_unpaid, 'deductions', v_ded, 'net', v_net,
    'holdover_days', v_days, 'holdover_claim', v_claim, 'total_owed', v_total, 'pay_by', v_pay_by,
    'template_id', (select id from letter_templates where template_key = v_tpl), 'subject', 'Notice to Return Security Deposit', 'html', v_html,
    'email_subject', v_subject, 'email_html', v_email);
end;
$function$;

CREATE OR REPLACE FUNCTION public.notice_build(p_template text, p_lease uuid, p_mail_on date, p_details jsonb, p_sender_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l leases; r jsonb; d jsonb := coalesce(p_details, '{}'::jsonb); v_mail date := coalesce(p_mail_on, current_date);
  v_days int; v_deadline date; v_given date; v_title text; v_statute text; v_extra jsonb; v_html text; v_email text; v_subject text;
  v_prior date; v_reason text; v_due numeric; v_cur numeric; v_month date; v_warn text := ''; v_end date; v_txt text := ''; v_short text := ''; v_quote text := ''; v_conseq text := '';
  money_ text := 'FM$999,990.00'; v_fmt text := 'FMDay, FMMonth FMDD, YYYY';
  v_service text := coalesce((select value from portal_settings where key = 'notice_service'), 'certified_mail');
  v_mm boolean;
begin
  if p_template = '2c-pay-or-vacate' then
    return pay_or_vacate_notice(p_lease, v_mail, p_sender_email) || jsonb_build_object('warning',
      case when (select federal_program from leases where id = p_lease) is not null then 'Section 8 / federal tenancy: send a copy of this notice to the housing authority.' else '' end);
  end if;
  select * into l from leases where id = p_lease;
  if l.id is null then raise exception 'Lease not found'; end if;
  r := lease_notice_rules(l.id);
  v_mm := l.lease_type = 'at_will';
  v_given := notice_deadline(v_mail, 1);
  if l.federal_program is not null then
    v_warn := 'Section 8 / federal tenancy: send a copy of this notice to the housing authority.';
  end if;

  if p_template = '2c-breach-cure' then
    if length(trim(coalesce(d->>'breach', ''))) < 10 then raise exception 'Describe the breach: what happened, where and when.'; end if;
    if length(trim(coalesce(d->>'cure', ''))) < 5 then raise exception 'Say what the tenant must do to remedy it.'; end if;
    v_days := (r->>'breach_cure_days')::int;
    v_deadline := notice_deadline(v_mail, v_days);
    v_title := case v_days when 5 then 'FIVE-DAY NOTICE TO REMEDY BREACH OR VACATE' else 'THIRTY-DAY NOTICE TO REMEDY BREACH OR VACATE' end;
    v_statute := case when r->>'lease_kind' = 'fixed_over_1_year' then 'Wis. Stat. § 704.17(3)' when v_mm then 'Wis. Stat. § 704.17(1p)(b)' else 'Wis. Stat. § 704.17(2)(b)' end;
    v_txt := case when r->>'lease_kind' = 'fixed_over_1_year' then '' else
      '<p>If, within one year of this notice, you break your rental agreement again, the landlord may end your tenancy with a 14-day notice without giving you a chance to remedy it.</p>' end;
    if nullif(trim(coalesce(d->>'lease_quote', '')), '') is not null then
      v_quote := '<p>Your lease says: &ldquo;' || repair_esc(trim(d->>'lease_quote')) || '&rdquo;</p>';
    end if;
    if nullif(trim(coalesce(d->>'consequence', '')), '') is not null then
      v_conseq := '<p><b>If it is not remedied:</b> ' || repair_esc(trim(d->>'consequence')) || '</p>';
    end if;
    v_extra := jsonb_build_object('Provision', coalesce(nullif(trim(d->>'provision'), ''), 'your lease and its rules'), 'Breach', trim(d->>'breach'), 'Cure', trim(d->>'cure'),
      'Repeat_Text', '[[REPEAT]]');

  elsif p_template = '2c-14-day' then
    v_reason := coalesce(d->>'reason', 'rent');
    if v_reason not in ('rent', 'breach') then raise exception 'Choose unpaid rent or a breach.'; end if;
    if r->>(case v_reason when 'rent' then 'nonpayment_14_day' else 'breach_14_day' end) = 'no' then
      raise exception '%', case when l.federal_program is not null and v_reason = 'rent' then 'This is a federally covered tenancy: unpaid rent needs the 30-day notice, not a 14-day notice.'
                                else 'A lease longer than one year can''t be ended with a 14-day notice. Use the 30-day notice.' end;
    end if;
    v_prior := coalesce(nullif(d->>'prior_notice_on', '')::date, notice_prior_within_year(l.id, v_reason, v_mail));
    if v_prior is not null and v_prior < v_mail - 365 then v_prior := null; end if;
    if not v_mm and v_prior is null then
      raise exception 'A lease of a year or less can only get a 14-day notice within a year of an earlier % notice. None is on file: send the 5-day notice instead, or enter the earlier notice''s date.',
        case v_reason when 'rent' then 'pay-or-vacate' else 'breach' end;
    end if;
    v_days := 14;
    v_deadline := notice_deadline(v_mail, 14);
    v_title := 'FOURTEEN-DAY NOTICE TO VACATE';
    v_statute := 'Wis. Stat. § 704.17' || case when v_mm then '(1p)' || case v_reason when 'rent' then '(a)' else '(b)' end else '(2)' || case v_reason when 'rent' then '(a)' else '(b)' end end;
    if v_reason = 'rent' then
      v_due := lease_rent_due(l.id, v_mail);
      if v_due <= 0 then raise exception 'This lease has no unpaid rent.'; end if;
      v_month := date_trunc('month', v_mail)::date;
      v_cur := least(v_due, greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id and kind = 'charge'
        and gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', entry_date) = v_month), 0));
      v_txt := 'You are in default in the payment of rent. Unpaid rent: <b>' || to_char(v_due, money_) || '</b> (' || to_char(v_month, 'FMMonth YYYY') || ': ' ||
        to_char(v_cur, money_) || '; earlier months: ' || to_char(v_due - v_cur, money_) || ').';
      v_short := 'Rent of ' || to_char(v_due, money_) || ' is unpaid.';
    else
      if length(trim(coalesce(d->>'breach', ''))) < 10 then raise exception 'Describe the breach: what happened, where and when.'; end if;
      v_txt := 'You have broken your rental agreement: ' || repair_esc(trim(d->>'breach'));
      v_short := 'It is for a violation of your rental agreement.';
    end if;
    v_extra := jsonb_build_object('Reason_Text', '[[REASON]]', 'Reason_Short', '[[SHORT]]',
      'Prior_Text', case when v_prior is null then '' else '[[PRIOR]]' end);

  elsif p_template = '2c-28-day' then
    if not v_mm then raise exception 'Only a month-to-month tenancy is ended with a 28-day notice. A lease for a term ends on its end date: use the Notice of Nonrenewal (Renewals page).'; end if;
    if l.federal_program is not null and length(trim(coalesce(d->>'reason', ''))) < 10 then
      raise exception 'Section 8 / federal tenancy: state the cause for ending it (the HAP contract requires good cause).';
    end if;
    -- First month-end that is at least 28 days after the notice is given (given day = day 1).
    v_end := (date_trunc('month', v_given + 27) + interval '1 month' - interval '1 day')::date;
    if nullif(d->>'end_on', '') is not null then
      if (d->>'end_on')::date < v_end then raise exception 'The tenancy can end no earlier than %.', to_char(v_end, 'FMMM/FMDD/YYYY'); end if;
      if (d->>'end_on')::date <> (date_trunc('month', (d->>'end_on')::date) + interval '1 month' - interval '1 day')::date then raise exception 'A month-to-month tenancy ends on the last day of a month.'; end if;
      v_end := (d->>'end_on')::date;
    end if;
    v_days := 28; v_deadline := v_end;
    v_title := '28-DAY NOTICE TERMINATING MONTH-TO-MONTH TENANCY';
    v_statute := 'Wis. Stat. § 704.19';
    v_extra := jsonb_build_object('Termination_Date', to_char(v_end, v_fmt),
      'Reason_Text', case when nullif(trim(d->>'reason'), '') is null then '' else '[[REASON]]' end);
    v_txt := case when nullif(trim(d->>'reason'), '') is null then '' else '<p>Reason: ' || repair_esc(trim(d->>'reason')) || '</p>' end;
  else
    raise exception 'Unknown notice %.', p_template;
  end if;

  v_extra := v_extra || jsonb_build_object('_keep_signature', true, 'Tenant_First_Name', '[[FIRST]]',
    'Notice_Title', v_title, 'Notice_Statute', v_statute, 'Notice_Days', v_days::text,
    'Notice_Date', to_char(v_mail, 'FMMonth FMDD, YYYY'), 'Mail_Date', to_char(v_mail, 'FMMonth FMDD, YYYY'),
    'Deadline', to_char(v_deadline, v_fmt), 'Service_Method', case v_service when 'personal' then 'personal delivery' else 'certified mail' end);
  v_html := letter_fill((select html from letter_templates where template_key = p_template), l.id, v_extra);
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where template_key = p_template;
  -- Parts built here from escaped values go in unescaped.
  v_html := replace(replace(replace(replace(v_html, '[[REPEAT]]', v_txt), '[[REASON]]', v_txt), '[[SHORT]]', v_short),
    '[[PRIOR]]', coalesce('<p>You were given a ' || case v_reason when 'rent' then 'notice for unpaid rent' else 'notice for breaking your rental agreement' end ||
      ' on ' || to_char(v_prior, 'FMMonth FMDD, YYYY') || ', less than one year ago.</p>', ''));
  v_html := replace(replace(v_html, '[[QUOTE]]', v_quote), '[[CONSEQ]]', v_conseq);
  v_email := replace(replace(v_email, '[[SHORT]]', v_short), '[[REASON]]', v_txt);

  return jsonb_build_object('template_id', (select id from letter_templates where template_key = p_template), 'template_name', (select name from letter_templates where template_key = p_template),
    'subject', case p_template when '2c-breach-cure' then case v_days when 5 then 'Five-Day' else 'Thirty-Day' end || ' Notice to Remedy Breach or Vacate'
      when '2c-14-day' then 'Fourteen-Day Notice to Vacate' else '28-Day Notice Terminating Tenancy' end, 'html', v_html, 'email_subject', v_subject, 'email_html', v_email,
    'days', v_days, 'deadline', v_deadline, 'prior_notice_on', v_prior, 'federal_program', l.federal_program, 'warning', v_warn);
end;
$function$;

CREATE OR REPLACE FUNCTION public.notice_prior_within_year(p_lease uuid, p_kind text, p_on date)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select max(coalesce(n.served_on, n.sent_at::date)) from notices n left join letter_templates t on t.id = n.template_id
  where n.lease_id = p_lease and not n.voided and n.status = 'sent' and coalesce(n.served_on, n.sent_at::date) between p_on - 365 and p_on
    and case p_kind
      when 'rent' then t.template_key = '2c-pay-or-vacate' or n.template_name in ('01_ROCA1_5day_balance', '02_Pay Rent or Quit - ROCA1', 'Notice to Pay Rent or Quit - RH')
      else t.template_key = '2c-breach-cure' or n.template_name in ('Breach', 'All Breach', '5-day Breach Pet', '5-Day-Pets', 'Breach of Utilities') end;
$function$;

CREATE OR REPLACE FUNCTION public.owner_staff_profile(p_owner uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o condo_owners; v_units text[]; v_emails text[];
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into o from condo_owners where id = p_owner;
  if o.id is null then raise exception 'Owner not found'; end if;
  select coalesce(array_agg(u.unit_number order by u.unit_number), '{}') into v_units
    from condo_ownerships s join condo_units u on u.id = s.unit_id where s.owner_id = o.id and s.is_current;
  v_emails := array_remove(array[lower(o.email), lower(o.alt_email)], null);

  return jsonb_build_object(
    'owner', to_jsonb(o) || jsonb_build_object('units', condo_unit_label(o.id), 'is_current', cardinality(v_units) > 0),
    'ownerships', coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_number, 'address', u.address, 'pin', u.pin, 'occupancy', u.occupancy, 'start', s.start_date, 'end', s.end_date,
          'current', s.is_current, 'dues', s.fee, 'board_position', s.board_position,
          'balance', coalesce((select sum(e.amount) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id where a.ownership_id = s.id and not a.excluded), 0),
          'last_payment', (select jsonb_build_object('date', e.entry_date, 'amount', -e.amount) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                           where a.ownership_id = s.id and e.kind = 'payment' order by e.entry_date desc, e.id desc limit 1))
        order by s.is_current desc, s.start_date desc nulls last) from condo_ownerships s join condo_units u on u.id = s.unit_id where s.owner_id = o.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('unit', x.unit_number, 'date', x.entry_date, 'kind', x.kind, 'description', x.description, 'amount', x.amount) order by x.entry_date desc, x.id desc)
        from (select e.*, u.unit_number from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
              join condo_ownerships s on s.id = a.ownership_id where s.owner_id = o.id and s.is_current and not a.excluded order by e.entry_date desc, e.id desc limit 60) x), '[]'::jsonb),
    'collections', coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_number, 'date', c.step_date, 'step', c.step, 'amount', c.amount, 'note', c.note) order by c.step_date desc)
        from condo_collection_steps c join condo_units u on u.id = c.unit_id where u.unit_number = any (v_units)), '[]'::jsonb),
    'violations', coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_number, 'category', v.category, 'description', v.description, 'observed', v.observed_date, 'status', v.status,
          'fine', v.fine_amount, 'resolution', v.resolution_note) order by v.observed_date desc)
        from condo_violations v join condo_units u on u.id = v.unit_id where v.owner_id = o.id or u.unit_number = any (v_units)), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('at', n.created_at, 'by', n.entered_by, 'note', n.note) order by n.created_at desc) from condo_owner_notes n where n.owner_id = o.id), '[]'::jsonb),
    'board', coalesce((select jsonb_agg(jsonb_build_object('position', t.position, 'start', t.start_date, 'end', t.end_date, 'note', t.note) order by t.start_date desc nulls last) from condo_board_terms t where t.owner_id = o.id), '[]'::jsonb),
    'updates', coalesce((select jsonb_agg(jsonb_build_object('at', p.created_at, 'kind', p.kind, 'via', p.via, 'changes', p.changes) order by p.created_at desc)
        from (select * from condo_profile_updates where owner_id = o.id order by created_at desc limit 30) p), '[]'::jsonb),
    'payment_reports', coalesce((select jsonb_agg(jsonb_build_object('at', r.created_at, 'method', r.method, 'amount', r.amount, 'paid_on', r.paid_on, 'status', r.status, 'note', r.note) order by r.created_at desc)
        from (select * from payment_reports where owner_id = o.id order by created_at desc limit 20) r), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('at', x.created_at, 'to', x.to_email, 'subject', x.subject, 'kind', x.kind, 'sent', x.sent_at is not null) order by x.created_at desc)
        from (select * from email_outbox where lower(to_email) = any (v_emails) order by created_at desc limit 50) x), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'email', m.email, 'message', m.message) order by m.created_at desc)
        from contact_messages m where lower(m.email) = any (v_emails)), '[]'::jsonb),
    'tenants', coalesce((select jsonb_agg(jsonb_build_object('unit', ru.unit_number, 'tenants', l.tenants_label, 'rent', l.rent, 'since', l.start_date,
          'balance', coalesce((select sum(e.amount) from lease_ledger_entries e where e.lease_id = l.id and e.gl_account = 'Rent Income'), 0),
          'contacts', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone)) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id), '[]'::jsonb))
        order by ru.unit_number) from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = any (v_units)), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('unit', v.unit_number, 'kind', v.kind, 'summary', vehicle_summary(v)) order by v.unit_number) from vehicles v where v.status = 'active' and v.unit_number = any (v_units)), '[]'::jsonb),
    'alert_prefs', (select prefs from condo_alert_prefs where owner_id = o.id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.pay_or_vacate_notice(p_lease uuid, p_mail_on date, p_sender_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l leases; r jsonb; s jsonb; v_days int; v_given date; v_deadline date; v_month date;
  v_due numeric; v_cur_charge numeric; v_cur numeric; v_prior numeric;
  v_service text; v_title text; v_statute text; v_fed text := ''; v_extra jsonb; v_html text; v_email text; v_subject text;
  money_ text := 'FM$999,990.00';
begin
  select * into l from leases where id = p_lease;
  if l.id is null then raise exception 'Lease not found'; end if;
  select jsonb_object_agg(key, value) into s from portal_settings;
  r := lease_notice_rules(l.id);
  v_days := (r->>'nonpayment_days')::int;
  v_service := coalesce(s->>'notice_service', 'certified_mail');
  v_given := p_mail_on + case when v_service = 'personal' then 0 else coalesce((s->>'notice_mail_days')::int, 0) end;
  v_deadline := v_given + v_days - 1;   -- the day given is day 1
  v_month := date_trunc('month', p_mail_on)::date;

  v_due := lease_rent_due(l.id, p_mail_on);
  select coalesce(sum(amount), 0) into v_cur_charge from lease_ledger_entries
    where lease_id = l.id and kind = 'charge' and gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', entry_date) = v_month;
  v_cur := least(v_due, greatest(v_cur_charge, 0));
  v_prior := v_due - v_cur;

  v_title := case v_days when 5 then 'FIVE-DAY NOTICE TO PAY RENT OR VACATE' when 30 then 'THIRTY-DAY NOTICE TO PAY RENT OR VACATE' else v_days || '-DAY NOTICE TO PAY RENT OR VACATE' end;
  v_statute := case
    when l.federal_program is not null then 'Wis. Stat. § 704.17 and CARES Act § 4024(c), 15 U.S.C. § 9058(c)'
    when r->>'lease_kind' = 'fixed_over_1_year' then 'Wis. Stat. § 704.17(3)'
    when r->>'lease_kind' = 'month_to_month' then 'Wis. Stat. § 704.17(1p)(a)'
    else 'Wis. Stat. § 704.17(2)(a)' end;
  if l.federal_program is not null then
    v_fed := '<p>Because your tenancy is ' || case when l.federal_program = 'section8' then 'under the Section 8 Housing Choice Voucher program' else 'federally covered' end ||
      ', federal law requires at least 30 days'' notice before you can be required to vacate for nonpayment. This notice gives you 30 days.</p>';
  end if;

  v_extra := jsonb_build_object('_keep_signature', true, 'Tenant_First_Name', '[[FIRST]]',
    'Notice_Title', v_title, 'Notice_Statute', v_statute, 'Notice_Days', v_days::text,
    'Notice_Date', to_char(p_mail_on, 'FMMonth FMDD, YYYY'), 'Mail_Date', to_char(p_mail_on, 'FMMonth FMDD, YYYY'),
    'Deadline', to_char(v_deadline, 'FMDay, FMMonth FMDD, YYYY'),
    'Service_Method', case v_service when 'personal' then 'personal delivery' else 'certified mail' end,
    'Rent_Month', to_char(v_month, 'FMMonth YYYY'), 'Current_Unpaid', to_char(v_cur, money_), 'Prior_Unpaid', to_char(v_prior, money_),
    'Amount_Required', to_char(v_due, money_),
    'Federal_Paragraph', '[[FED]]');
  v_html := replace(letter_fill((select html from letter_templates where template_key = '2c-pay-or-vacate'), l.id, v_extra), '[[FED]]', v_fed);
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where template_key = '2c-pay-or-vacate';

  return jsonb_build_object('template_id', (select id from letter_templates where template_key = '2c-pay-or-vacate'), 'template_name', '2nd Chance — Notice to Pay Rent or Vacate',
    'subject', case v_days when 5 then 'Five-Day Notice to Pay Rent or Vacate' when 30 then 'Thirty-Day Notice to Pay Rent or Vacate' else v_days || '-Day Notice to Pay Rent or Vacate' end, 'html', v_html, 'email_subject', v_subject, 'email_html', v_email,
    'days', v_days, 'given_on', v_given, 'deadline', v_deadline, 'amount_required', v_due,
    'federal_program', l.federal_program, 'basis', r->>'nonpayment_basis');
end;
$function$;

CREATE OR REPLACE FUNCTION public.payments_auto_match()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
          or (l.account_number is not null and coalesce(b.description, '') || coalesce(b.reference, '') like '%' || l.account_number || '%')
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
$function$;

CREATE OR REPLACE FUNCTION public.payments_staff_queue()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reports', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
        'tenant', coalesce(t.name, o.name || ' (owner)'),
        'account_number', coalesce(l.account_number, cu.pin),
        'unit', coalesce(u.unit_number, case when cu.unit_number is not null then 'ROCA ' || cu.unit_number || ' dues' end),
        'side', payment_report_side(r),
        'receipt', (select to_jsonb(b) - 'raw' from bank_receipts b where b.id = r.bank_receipt_id)) order by r.created_at desc)
      from payment_reports r left join tenants t on t.id = r.tenant_id left join condo_owners o on o.id = r.owner_id
      left join leases l on l.id = r.lease_id left join rental_units u on u.id = l.unit_id
      left join condo_ledger_accounts ca on ca.id = r.condo_account_id left join condo_units cu on cu.id = ca.unit_id
      where r.created_at > now() - interval '120 days'), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'bank_key', a.bank_key, 'truth_source', a.truth_source) order by a.kind desc) from bank_accounts a where a.active), '[]'::jsonb),
    'unmatched_receipts', coalesce((select jsonb_agg(to_jsonb(b) - 'raw' || jsonb_build_object('side', bank_receipt_side(b.id)) order by b.posted_on desc)
      from bank_receipts b where b.matched_report_id is null and b.assigned_lease_id is null and not b.ignored
        and b.status not in ('posted', 'stripe_payout', 'ignored') and b.posted_on > current_date - 120), '[]'::jsonb));
end;
$function$;

CREATE OR REPLACE FUNCTION public.renewal_staff_non_renewal(p_lease uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l leases; v_id uuid;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and status = 'active';
  if l.id is null or l.lease_type <> 'fixed' or l.end_date is null then raise exception 'Only a lease for a term can be non-renewed. A month-to-month tenancy ends with a 28-day notice (Notices page).'; end if;
  if l.end_date < current_date then raise exception 'This lease already ended.'; end if;
  if exists (select 1 from lease_renewals where lease_id = p_lease and status in ('accepted', 'signed')) then raise exception 'The tenant already accepted a renewal.'; end if;
  update lease_renewals set status = 'withdrawn' where lease_id = p_lease and status = 'offered';
  insert into lease_renewals (lease_id, status, current_rent, offered_by, note, answered_at) values (p_lease, 'non_renewal', l.rent, auth.email(), nullif(trim(p_note), ''), now())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'renewal_id', v_id, 'lease_id', p_lease, 'template_id', (select id from letter_templates where template_key = '2c-non-renewal'),
    'subject', 'Notice of Nonrenewal of Lease', 'days_left', l.end_date - current_date,
    'html', letter_render_ctx('2c-non-renewal', p_lease, jsonb_build_object('_keep_signature', true, 'NonRenewal_Note', coalesce(nullif(trim(p_note), ''), ''))));
end;
$function$;

CREATE OR REPLACE FUNCTION public.rent_change_staff(p_lease uuid, p_new_rent numeric, p_effective date, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l leases; v_id uuid;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and status = 'active';
  if l.id is null then raise exception 'Lease not found.'; end if;
  if l.lease_type <> 'at_will' then raise exception 'During a lease for a term the rent changes at renewal. Send a renewal offer instead.'; end if;
  if p_new_rent is null or p_new_rent < 100 or p_new_rent > 10000 or p_new_rent = l.rent then raise exception 'Enter the new rent.'; end if;
  if p_effective is null or extract(day from p_effective) <> 1 then raise exception 'The change must start on the 1st of a month (the start of a rental period).'; end if;
  if p_effective < current_date + 28 then raise exception 'The change must be at least 28 days from today: the earliest is %.',
    to_char((date_trunc('month', current_date + 28) + case when extract(day from current_date + 28) = 1 then interval '0' else interval '1 month' end)::date, 'FMMonth FMDD, YYYY'); end if;
  update lease_rent_changes set canceled_at = now() where lease_id = p_lease and applied_at is null and canceled_at is null and reason = 'rent_change';
  insert into lease_rent_changes (lease_id, new_rent, effective_on, reason, created_by) values (p_lease, round(p_new_rent, 2), p_effective, 'rent_change', auth.email()) returning id into v_id;
  return jsonb_build_object('ok', true, 'change_id', v_id, 'lease_id', p_lease, 'template_id', (select id from letter_templates where template_key = '2c-rent-change'),
    'subject', 'Notice of Change of Rent',
    'html', letter_render_ctx('2c-rent-change', p_lease, jsonb_build_object('_keep_signature', true, 'Effective_Date', to_char(p_effective, 'FMMonth FMDD, YYYY'),
      'New_Rent', to_char(round(p_new_rent, 2), 'FM$999,990.00'), 'Rent_Change_Note', coalesce(nullif(trim(p_note), ''), ''))));
end;
$function$;

CREATE OR REPLACE FUNCTION public.rent_unpaid(p_as_of date)
 RETURNS TABLE(lease_id uuid, unit_label text, address text, rent_due numeric, pending_reported numeric, tenants jsonb, account_number text, property_key text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select l.id, coalesce(u.unit_number, ''), u.address, lease_rent_due(l.id, p_as_of),
         coalesce((select sum(r.amount) from payment_reports r where r.lease_id = l.id and r.status = 'pending' and payment_report_fresh(r, p_as_of)), 0)
           + coalesce((select sum(s.amount) from stripe_payments s where s.lease_id = l.id and s.status = 'processing'), 0),
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
         l.account_number, p.key
  from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
  where l.status = 'active' and lease_rent_due(l.id, p_as_of) > 0;
$function$;

CREATE OR REPLACE FUNCTION public.rentals_staff_ledger(p_lease_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'date', e.entry_date, 'gl', e.gl_account, 'kind', e.kind, 'type', e.raw_type, 'description', e.description,
      'amount', e.amount, 'note', e.correction_note)
      order by e.entry_date, e.id)
    from lease_ledger_entries e where e.lease_id = p_lease_id), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.rentals_staff_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'property', p.name, 'property_key', p.key, 'unit_number', u.unit_number, 'address', u.address,
        'managed_by', u.managed_by, 'management_note', u.management_note,
        'condo_occupancy', cu.occupancy, 'bedrooms', cu.bedrooms, 'bathrooms', cu.bathrooms, 'size_sqft', cu.size_sqft,
        'leases', coalesce((select jsonb_agg(jsonb_build_object(
            'id', l.id, 'status', l.status, 'lease_type', l.lease_type, 'start_date', l.start_date, 'end_date', l.end_date,
            'rent', l.rent, 'tenants_label', l.tenants_label, 'balance', b.balance,
            'entries', b.entries, 'correction_note', l.correction_note,
            'deposit_held', l.deposit_held, 'account_number', l.account_number,
            'work_agreements', (select count(*) from work_agreements w where w.lease_id = l.id),
            'tenants', (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone) order by t.name)
                        from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id))
            order by l.start_date desc nulls last)
          from leases l join lease_balances b on b.lease_id = l.id where l.unit_id = u.id), '[]'::jsonb))
        order by p.key <> 'roca1', p.name, nullif(regexp_replace(coalesce(u.unit_number, ''), '\D', '', 'g'), '')::int nulls last)
      from rental_units u join rental_properties p on p.id = u.property_id
      left join condo_units cu on cu.id = u.condo_unit_id), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.report_age(p_balance numeric, p_dates date[], p_amts numeric[], p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare left_ numeric := greatest(coalesce(p_balance, 0), 0); r record; take numeric; d int;
  b0 numeric := 0; b1 numeric := 0; b2 numeric := 0; b3 numeric := 0;
begin
  for r in select x.d, x.a from unnest(p_dates, p_amts) as x(d, a) where x.a > 0 order by x.d desc loop
    exit when left_ <= 0;
    take := least(left_, r.a); left_ := left_ - take; d := p_as_of - r.d;
    if d <= 30 then b0 := b0 + take; elsif d <= 60 then b1 := b1 + take; elsif d <= 90 then b2 := b2 + take; else b3 := b3 + take; end if;
  end loop;
  b3 := b3 + left_;   -- owed beyond every charge on file (e.g. an imported opening balance): oldest bucket
  return jsonb_build_object('d0_30', b0, 'd31_60', b1, 'd61_90', b2, 'd90p', b3);
end $function$;

CREATE OR REPLACE FUNCTION public.report_condo_accounts()
 RETURNS TABLE(account_id uuid, unit_number text, owner_label text, is_current boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select a.id, u.unit_number,
         coalesce((select o.name from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.id = a.ownership_id), a.owner_label),
         coalesce((select s.is_current from condo_ownerships s where s.id = a.ownership_id), false)
  from condo_ledger_accounts a join condo_units u on u.id = a.unit_id
  where not a.excluded and u.address not ilike '%Test Way%';
$function$;

CREATE OR REPLACE FUNCTION public.report_deposits_held()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'notes', jsonb_build_array('Today''s deposits, from the amount on file for each lease (the statements on file for imported leases). The Security Deposit Liability lines in the imported ledgers are not used for this total.',
      'Moved-out tenants stay on the list until their itemized deposit statement is sent (21 days, Wis. Stat. § 704.28).'));
end $function$;

CREATE OR REPLACE FUNCTION public.report_income_by_gl(p_side text, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    select coalesce(x.gl_account, x.kind), date_trunc('month', x.entry_date)::date,
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
end $function$;

CREATE OR REPLACE FUNCTION public.report_receipts(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           -sum(x.amount), string_agg(coalesce(x.gl_account, '') || ' ' || to_char(-x.amount, 'FM999,990.00'), '; ' order by x.id), 'zz'
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
end $function$;

CREATE OR REPLACE FUNCTION public.resident_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ids uuid[] := array(select resident_me());
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'name', (select name from tenants where id = v_ids[1]),
    'settings', (select jsonb_object_agg(key, value) from portal_settings),
    'leases', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'status', l.status, 'former', l.status = 'past', 'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'move_in_charges_posted', l.move_in_charges_posted, 'account_number', coalesce(l.account_number, upper(left(l.id::text, 8))), 'address', coalesce(u.address, p.street), 'unit_number', u.unit_number,
        'pay_to', (select jsonb_build_object('name', a.name, 'entity', a.entity, 'kind', a.kind, 'zelle_to', a.pay_zelle_to, 'zelle_name', a.pay_zelle_name, 'zelle_qr', a.pay_zelle_qr, 'stripe_account', a.stripe_account, 'bank_transfer', a.pay_bank_transfer, 'note', a.pay_note) from bank_accounts a where a.id = l.pay_to_account_id),
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
$function$;

CREATE OR REPLACE FUNCTION public.tenant_codes_issue_active(p_reissue boolean)
 RETURNS TABLE(tenant_id uuid, tenant_name text, unit_number text, address text, account_number text, code text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v text;
begin
  for r in
    select distinct on (t.id) t.id, t.name, u.unit_number, u.address, l.account_number acct
      from leases l join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id join rental_units u on u.id = l.unit_id
     where l.status in ('active', 'future')
       and (p_reissue or not exists (select 1 from tenant_reg_codes c where c.tenant_id = t.id))
     order by t.id, l.start_date desc
  loop
    loop
      v := reg_code_make();
      exit when not exists (select 1 from tenant_reg_codes c2 where c2.code_hash = encode(sha256(convert_to(v, 'UTF8')), 'hex'));
    end loop;
    insert into tenant_reg_codes (tenant_id, code_hash, issued_by) values (r.id, encode(sha256(convert_to(v, 'UTF8')), 'hex'), 'launch notices')
    on conflict on constraint tenant_reg_codes_pkey do update set code_hash = excluded.code_hash, issued_at = now(), issued_by = excluded.issued_by, used_at = null, failed_tries = 0;
    tenant_id := r.id; tenant_name := r.name; unit_number := r.unit_number; address := r.address; account_number := r.acct; code := v;
    return next;
  end loop;
end;
$function$;

