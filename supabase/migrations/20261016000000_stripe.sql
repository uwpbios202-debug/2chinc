-- Stripe: "Pay now" (bank account or card) and autopay (bank account), with
-- 2nd Chance paying every fee (tenant-journey-spec rule 9). We never see or
-- store bank or card numbers: Stripe Checkout collects them, and Stripe's
-- signed webhooks tell us when a payment succeeds, which then posts it to the
-- ledger as a payment verified by Stripe.

alter table payment_reports drop constraint if exists payment_reports_method_check;
alter table payment_reports add constraint payment_reports_method_check
  check (method in ('zelle', 'cashapp', 'paypal', 'bank_transfer', 'money_order', 'check', 'cash', 'other', 'stripe_bank', 'stripe_card'));

create table if not exists stripe_customers (
  tenant_id uuid primary key references tenants(id),
  customer_id text not null unique,
  autopay_enabled boolean not null default false,
  autopay_payment_method text,
  autopay_bank_label text,            -- e.g. "Chase ••••6789" (Stripe's display, no full numbers)
  autopay_since timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists stripe_payments (
  id uuid primary key default gen_random_uuid(),
  payment_intent text unique,
  checkout_session text unique,
  tenant_id uuid references tenants(id),
  lease_id uuid references leases(id),
  land_contract_id uuid references land_contracts(id),
  amount numeric(12,2) not null,
  method_type text,                   -- us_bank_account | card
  origin text not null default 'pay_now' check (origin in ('pay_now', 'autopay')),
  status text not null default 'created' check (status in ('created', 'processing', 'succeeded', 'failed', 'canceled')),
  failure_message text,
  payment_report_id uuid references payment_reports(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists stripe_events (id text primary key, type text not null, received_at timestamptz not null default now());

alter table stripe_customers enable row level security;
alter table stripe_payments enable row level security;
alter table stripe_events enable row level security;

-- Called by the webhook when Stripe says a payment succeeded: one verified
-- payment report, posted to the ledger once (receipt follows via the trigger).
create or replace function stripe_payment_succeeded(p_intent text, p_method_type text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare s stripe_payments; v_report uuid;
begin
  select * into s from stripe_payments where payment_intent = p_intent for update;
  if s.id is null then return jsonb_build_object('error', 'unknown payment intent'); end if;
  if s.status = 'succeeded' then return jsonb_build_object('ok', true, 'already', true); end if;
  insert into payment_reports (tenant_id, lease_id, land_contract_id, method, amount, paid_on, confirmation_code, note)
  values (s.tenant_id, s.lease_id, s.land_contract_id, case when coalesce(p_method_type, s.method_type) = 'card' then 'stripe_card' else 'stripe_bank' end,
          s.amount, current_date, p_intent, case s.origin when 'autopay' then 'Autopay' else 'Paid online' end)
  returning id into v_report;
  perform payment_post(v_report, null, 'stripe', 'Stripe');
  update stripe_payments set status = 'succeeded', method_type = coalesce(p_method_type, method_type), payment_report_id = v_report, updated_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'report', v_report);
end;
$$;
revoke all on function stripe_payment_succeeded(text, text) from public, anon, authenticated;
grant execute on function stripe_payment_succeeded(text, text) to service_role;

-- What a resident owes now and their autopay status (for "Pay now").
create or replace function resident_stripe_status()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me());
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'autopay', (select jsonb_build_object('enabled', c.autopay_enabled, 'bank', c.autopay_bank_label, 'since', c.autopay_since) from stripe_customers c where c.tenant_id = any(v_ids) limit 1),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('amount', p.amount, 'status', p.status, 'origin', p.origin, 'method', p.method_type, 'created_at', p.created_at,
        'failure', p.failure_message) order by p.created_at desc) from (select * from stripe_payments where tenant_id = any(v_ids) order by created_at desc limit 10) p), '[]'::jsonb));
end;
$$;
revoke all on function resident_stripe_status() from public, anon;
grant execute on function resident_stripe_status() to authenticated;

-- Autopay tenants with rent due (for the rent cycle on the 1st).
create or replace function autopay_due(p_as_of date)
returns table (tenant_id uuid, customer_id text, payment_method text, lease_id uuid, amount numeric)
language sql stable security definer set search_path = public as $$
  select distinct on (l.id) c.tenant_id, c.customer_id, c.autopay_payment_method, l.id, lease_rent_due(l.id, p_as_of)
  from stripe_customers c join lease_tenants x on x.tenant_id = c.tenant_id join leases l on l.id = x.lease_id and l.status = 'active'
  where c.autopay_enabled and c.autopay_payment_method is not null and lease_rent_due(l.id, p_as_of) > 0
    and not exists (select 1 from stripe_payments p where p.lease_id = l.id and p.status in ('created', 'processing'))
  order by l.id, c.autopay_since;
$$;
revoke all on function autopay_due(date) from public, anon, authenticated;
grant execute on function autopay_due(date) to service_role;

-- A Stripe payment still processing (bank payments take a few days) counts
-- as pending, so nobody gets "Pay or Vacate" while their payment clears.
create or replace function rent_unpaid(p_as_of date)
returns table (lease_id uuid, unit_label text, address text, rent_due numeric, pending_reported numeric, tenants jsonb, account_number text, property_key text)
language sql stable security definer set search_path = public as $$
  select l.id, coalesce(u.unit_number, ''), u.address, lease_rent_due(l.id, p_as_of),
         coalesce((select sum(r.amount) from payment_reports r where r.lease_id = l.id and r.status = 'pending'), 0)
           + coalesce((select sum(s.amount) from stripe_payments s where s.lease_id = l.id and s.status = 'processing'), 0),
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
         l.legacy_lease_number, p.key
  from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
  where l.status = 'active' and lease_rent_due(l.id, p_as_of) > 0;
$$;
