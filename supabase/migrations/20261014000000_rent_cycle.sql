-- Stage 4: the monthly rent cycle (tenant-journey-spec.md).
--
-- The rent-cycle function runs daily (pg_cron) and does each job once per day:
--   1st          post rent (and active work-in-lieu credits, land contract
--                installments); never twice, never over a charge already posted
--   1st - 3      rent reminder email to every tenant
--   2nd - 2      agent reminder: "the 2nd is a work and post office day" + who is unpaid
--   2nd 12:01    "Pay or Vacate" email to every tenant with unpaid rent (tenants whose
--                reported payment covers it get "we're verifying your payment")
--   2nd          5-day notices prepared as drafts for the agent to sign and print
--   3rd          process email: notice end, filing date, expected court date, writ
-- Receipts for verified payments go through email_outbox.

alter table leases add column if not exists late_fee numeric(12,2) not null default 75;

create table if not exists email_outbox (
  id bigint generated always as identity primary key,
  to_email text not null,
  subject text not null,
  html text not null,
  kind text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);
alter table email_outbox enable row level security;

create table if not exists rent_cycle_runs (
  job text not null,
  run_date date not null,
  ran_at timestamptz not null default now(),
  result jsonb,
  primary key (job, run_date)
);
alter table rent_cycle_runs enable row level security;

-- Court/business holidays used for the expected court date (edit as needed).
create table if not exists court_holidays (day date primary key, name text not null);
alter table court_holidays enable row level security;
insert into court_holidays (day, name) values
  ('2026-01-01', 'New Year''s Day'), ('2026-01-19', 'Martin Luther King Jr. Day'), ('2026-05-25', 'Memorial Day'), ('2026-07-03', 'Independence Day (observed)'),
  ('2026-09-07', 'Labor Day'), ('2026-11-26', 'Thanksgiving'), ('2026-11-27', 'Day after Thanksgiving'), ('2026-12-24', 'Christmas Eve'), ('2026-12-25', 'Christmas Day'),
  ('2026-12-31', 'New Year''s Eve'), ('2027-01-01', 'New Year''s Day'), ('2027-01-18', 'Martin Luther King Jr. Day'), ('2027-05-31', 'Memorial Day'),
  ('2027-07-05', 'Independence Day (observed)'), ('2027-09-06', 'Labor Day'), ('2027-11-25', 'Thanksgiving'), ('2027-11-26', 'Day after Thanksgiving'),
  ('2027-12-24', 'Christmas Eve'), ('2027-12-31', 'New Year''s Eve')
on conflict (day) do nothing;

insert into portal_settings (key, value) values
  ('notice_days', '5'),
  ('court_days_after_filing', '14'),
  ('writ_text', 'If the court grants a judgment for eviction, the court can issue a writ of restitution. The sheriff can then remove you and your belongings from the unit. An eviction judgment can make it much harder to rent in the future.')
on conflict (key) do nothing;

-- Notices can be drafts (prepared by the rent cycle, signed and printed by the agent).
alter table notices add column if not exists status text not null default 'sent' check (status in ('draft', 'sent'));
alter table notices add column if not exists batch text;
alter table notices alter column html_sha256 drop not null;

-- ---------------------------------------------------------------------------
create or replace function next_business_day(p_day date)
returns date
language sql stable as $$
  select min(d)::date from generate_series(p_day, p_day + 20, interval '1 day') d
  where extract(isodow from d) < 6 and not exists (select 1 from court_holidays h where h.day = d::date);
$$;

-- Unpaid RENT on a lease as of a date (late fees and other charges excluded).
create or replace function lease_rent_due(p_lease uuid, p_as_of date)
returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(coalesce(sum(amount), 0), 0) from lease_ledger_entries
  where lease_id = p_lease and gl_account in ('Rent Income', 'Rent Charge') and entry_date <= p_as_of;
$$;

-- Post the month's rent. Idempotent: skips a lease that already has a rent
-- charge dated in that month (from the earlier records or an earlier run).
create or replace function billing_post_month(p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare m date := date_trunc('month', p_month)::date; n_rent int := 0; n_credit int := 0; n_lc int := 0; r record;
begin
  for r in select l.id, l.rent from leases l
           where l.status = 'active' and coalesce(l.rent, 0) > 0 and coalesce(l.start_date, m) <= m + 27
             and (l.end_date is null or l.end_date >= m)
             and not exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge'
                             and e.gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', e.entry_date) = m)
  loop
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (r.id, 'Rent Income', m, 'charge', 'Charge', 'Rent', r.rent, 'billing');
    n_rent := n_rent + 1;
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
revoke all on function billing_post_month(date) from public, anon, authenticated;

-- Who owes rent as of a date, with tenant emails and pending payment reports.
create or replace function rent_unpaid(p_as_of date)
returns table (lease_id uuid, unit_label text, address text, rent_due numeric, pending_reported numeric, tenants jsonb, account_number text, property_key text)
language sql stable security definer set search_path = public as $$
  select l.id, coalesce(u.unit_number, ''), u.address, lease_rent_due(l.id, p_as_of),
         coalesce((select sum(r.amount) from payment_reports r where r.lease_id = l.id and r.status = 'pending'), 0),
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
         l.legacy_lease_number, p.key
  from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
  where l.status = 'active' and lease_rent_due(l.id, p_as_of) > 0;
$$;
revoke all on function rent_unpaid(date) from public, anon, authenticated;

-- The body of notice_context, shared by the staff RPC and the rent cycle.
create or replace function notice_context_body(p_lease_id uuid, p_sender_email text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  l leases; u rental_units; p rental_properties;
  v_owner text; v_tenants text; v_first text; v_last text; v_emails text; v_rent_balance numeric; v_balance numeric;
  v_sender text; v_sender_phone text; v_sender_email text := lower(coalesce(p_sender_email, ''));
begin
  select * into l from leases where id = p_lease_id;
  if l.id is null then raise exception 'Lease not found'; end if;
  select * into u from rental_units where id = l.unit_id;
  select * into p from rental_properties where id = u.property_id;
  select o.name into v_owner from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.unit_id = u.condo_unit_id and s.is_current order by s.start_date desc limit 1;
  select string_agg(t.name, ', ' order by t.name), string_agg(t.email, ', ' order by t.name) into v_tenants, v_emails
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id;
  select split_part(t.name, ' ', 1), regexp_replace(t.name, '^\S+\s*', '') into v_first, v_last
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id order by t.name limit 1;
  select coalesce(sum(amount), 0) into v_balance from lease_ledger_entries where lease_id = l.id;
  v_rent_balance := lease_rent_due(l.id, current_date);
  select coalesce(a.name, s.name), coalesce(a.phone_mobile, s.phone_mobile) into v_sender, v_sender_phone
    from condo_staff s left join lease_agents a on lower(a.email) = lower(s.email) where lower(s.email) = v_sender_email;
  return jsonb_build_object(
    'Current_Date', to_char(current_date, 'FMMonth FMDD, YYYY'), 'Current_Month', to_char(current_date, 'FMMonth'), 'Current_Year', to_char(current_date, 'YYYY'),
    'Unit_Address_Line_1', coalesce(regexp_replace(u.address, '\s*-\s*\d+$', ''), p.street), 'Unit_Number', coalesce(u.unit_number, ''),
    'Unit_Address', coalesce(u.address, p.street) || ', ' || coalesce(p.city, 'Milwaukee') || ', ' || coalesce(p.state, 'WI') || ' ' || coalesce(p.zip, ''),
    'Unit_City_Address', coalesce(p.city, 'Milwaukee'), 'Unit_City', coalesce(p.city, 'Milwaukee'),
    'Unit_State_Address', coalesce(p.state, 'WI'), 'Unit_State', coalesce(p.state, 'WI'),
    'Unit_PostalCode_Address', coalesce(p.zip, ''), 'Unit_Postal_Code', coalesce(p.zip, ''),
    'Property_Address_Line_1', coalesce(p.street, ''), 'Property_Name', p.name,
    'Rental_Owner_Full_Name', coalesce(v_owner, '2nd Chance Housing Inc.'), 'Rental_Owners_Full_Name', coalesce(v_owner, '2nd Chance Housing Inc.'),
    'Tenant_First_Name', coalesce(v_first, ''), 'Tenant_Last_Name', coalesce(v_last, ''), 'Tenants_Full_Name', coalesce(v_tenants, ''),
    'Lease_All_Tenants', coalesce(v_tenants, ''), 'Tenants_Email', coalesce(v_emails, ''), 'Tenant_Address_1', coalesce(u.address, p.street),
    'Lease_Rent', to_char(coalesce(l.rent, 0), 'FM$999,990.00'), 'Lease_Rent_Due_Day', '1st',
    'Rent_Balance', to_char(v_rent_balance, 'FM$999,990.00'), 'Account_Balance', to_char(v_balance, 'FM$999,990.00'),
    'Lease_Start_Date', to_char(l.start_date, 'FMMM/FMDD/YYYY'), 'Lease_End_Date', coalesce(to_char(l.end_date, 'FMMM/FMDD/YYYY'), 'month-to-month'),
    'Lease_Security_Deposit', to_char(coalesce(l.deposit_held, 0), 'FM$999,990.00'),
    'Sender_Name', coalesce(v_sender, ''), 'Sender_Phone', coalesce(v_sender_phone, (select value from portal_settings where key = 'office_phone')),
    'Sender_Email', coalesce(v_sender_email, ''), 'Sender_URL', '2ndchinc.org',
    '_lease_label', coalesce(u.address, p.street) || ' — ' || coalesce(v_tenants, ''),
    '_sender_is_agent', exists (select 1 from lease_agents a where a.active and lower(a.email) = v_sender_email and a.signature_path is not null)
  );
end;
$$;
revoke all on function notice_context_body(uuid, text) from public, anon, authenticated;

create or replace function notice_context(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return notice_context_body(p_lease_id, auth.email());
end;
$$;

-- Receipts: queue an email whenever a payment is verified.
create or replace function payment_receipt_trigger()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare t tenants; v_addr text; v_bal numeric;
begin
  if new.status = 'verified' and (old.status is distinct from 'verified') then
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
drop trigger if exists payment_reports_receipt on payment_reports;
create trigger payment_reports_receipt after update of status on payment_reports for each row execute function payment_receipt_trigger();

-- Staff: draft 5-day notices waiting for the agent, and recent cycle runs.
create or replace function rent_cycle_staff_status()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'drafts', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'subject', n.subject, 'batch', n.batch, 'lease_label', u.address || ' — ' || l.tenants_label,
        'created', n.sent_at) order by u.address) from notices n join leases l on l.id = n.lease_id join rental_units u on u.id = l.unit_id where n.status = 'draft'), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(to_jsonb(r) order by r.ran_at desc) from (select * from rent_cycle_runs order by ran_at desc limit 30) r), '[]'::jsonb));
end;
$$;
revoke all on function rent_cycle_staff_status() from public, anon;
grant execute on function rent_cycle_staff_status() to authenticated;

grant execute on function notice_context_body(uuid, text) to service_role;
grant execute on function rent_unpaid(date) to service_role;
grant execute on function billing_post_month(date) to service_role;
grant execute on function lease_rent_due(uuid, date) to service_role;
grant execute on function next_business_day(date) to service_role;
