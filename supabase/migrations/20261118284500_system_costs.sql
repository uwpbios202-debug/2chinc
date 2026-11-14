-- System costs tracking sheet (Stephen, 11/5/2026): https://2ndchinc.org/accounting/costs/ (office staff).
--  * system_cost_items: what the system costs to run (services, plans), as paid; monthly = amount / months it covers.
--  * system_cost_stripe: Stripe fees per month per Stripe account, read from Stripe by the system-costs function ("Refresh from Stripe").
--  * The "everyone pays by card" what-if is computed live from the active leases and land contracts (Stripe's standard US rates:
--    card 2.9% + 30 cents; bank account (ACH) 0.8%, at most $5).

create table if not exists system_cost_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  what text,
  amount numeric(10,2) not null default 0,     -- what is paid each time
  months int not null default 1 check (months between 1 and 240),   -- how many months one payment covers (1 monthly, 12 yearly, 36, 120 ...)
  status text not null default 'paying' check (status in ('paying', 'free', 'not_bought', 'stopped')),
  notes text,
  sort int not null default 100,
  updated_at timestamptz not null default now(),
  updated_by text
);

create table if not exists system_cost_stripe (
  month date not null,
  account text not null check (account in ('main', 'yawdcour', 'roca1')),
  payments int not null default 0,
  collected numeric(12,2) not null default 0,
  fees numeric(10,2) not null default 0,
  refreshed_at timestamptz not null default now(),
  primary key (month, account)
);

alter table system_cost_items enable row level security;
alter table system_cost_stripe enable row level security;
revoke all on table system_cost_items, system_cost_stripe from anon, authenticated;
grant all on table system_cost_items, system_cost_stripe to service_role;

insert into system_cost_items (name, what, amount, months, status, notes, sort)
select * from (values
  ('Claude', 'AI assistant that builds and runs the system', 20.00, 1, 'paying', 'Monthly subscription', 10),
  ('Microsoft 365 email (GoDaddy)', 'info@2ndchinc.org mailbox', 132.84, 36, 'paying', '3-year plan (Stephen to confirm what it covers)', 20),
  ('2ndchinc.org domain (GoDaddy)', 'The web address', 227.90, 120, 'paying', '10-year plan (Stephen to confirm)', 30),
  ('Plaid', 'Reads the 4 bank accounts (Transactions)', 1.20, 1, 'paying', '$0.30 per connected bank per month x 4. Auth, Balance and Identity are not used.', 40),
  ('Supabase', 'Database, sign-in, file storage, nightly jobs', 0, 1, 'free', 'Free plan: 32 MB of 500 MB data, 100 MB of 1 GB files (11/5/2026). No automatic backups.', 50),
  ('Cloudflare', 'Website hosting, DNS, Turnstile (anti-bot)', 0, 1, 'free', 'Free plan', 60),
  ('Resend', 'Sends all email', 0, 1, 'free', 'Free plan: 3,000 a month, 100 a day. About 330 a month (October 2026), busiest day 57.', 70),
  ('GitHub', 'Keeps the code', 0, 1, 'free', 'Free', 80),
  ('Twilio', 'Text-message codes (no longer used)', 0, 1, 'stopped', 'No phone numbers, $0 spent. Can be closed.', 90),
  ('Supabase Pro (recommended)', 'Daily database backups kept 7 days', 25.00, 1, 'not_bought', 'Recommended: the ledgers, leases and payments live only in this database.', 100),
  ('Resend Pro', 'Only if the 100-a-day email limit is reached often', 20.00, 1, 'not_bought', 'Emails over the limit wait and go out the next day.', 110)
) v(name, what, amount, months, status, notes, sort)
where not exists (select 1 from system_cost_items);

-- Real figures read from Stripe on 11/5/2026 (the Refresh button replaces them with fresh ones).
insert into system_cost_stripe (month, account, payments, collected, fees) values
  ('2026-10-01', 'main', 2, 1400.00, 30.93), ('2026-11-01', 'main', 2, 1525.00, 44.83),
  ('2026-10-01', 'yawdcour', 2, 876.00, 5.01), ('2026-11-01', 'yawdcour', 3, 2475.00, 15.00),
  ('2026-10-01', 'roca1', 2, 216.00, 1.73)
on conflict (month, account) do nothing;

create or replace function system_costs_view()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'what', what, 'amount', amount, 'months', months, 'status', status,
        'notes', notes, 'monthly', round(amount / months, 2), 'updated_at', updated_at, 'updated_by', updated_by) order by sort, name) from system_cost_items), '[]'::jsonb),
    'stripe', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'account', account, 'payments', payments, 'collected', collected, 'fees', fees, 'refreshed_at', refreshed_at)
        order by month desc, account) from system_cost_stripe), '[]'::jsonb),
    -- What if: every tenant pays their own monthly share online. Agency shares come by check or EFT, not through Stripe.
    'whatif', coalesce((select jsonb_agg(x order by x->>'label') from (
        select jsonb_build_object('label', ru.address, 'account', coalesce(ba.stripe_account, 'main'),
               'rent', l.rent, 'share', coalesce(lease_tenant_rent(l.id), l.rent)) x
          from leases l join rental_units ru on ru.id = l.unit_id left join bank_accounts ba on ba.id = l.pay_to_account_id
         where l.status = 'active'
        union all
        select jsonb_build_object('label', 'Land contract: ' || coalesce(rp.street, ''), 'account', 'main', 'rent', lc.monthly_payment, 'share', lc.monthly_payment)
          from land_contracts lc left join rental_properties rp on rp.id = lc.property_id
         where lc.status = 'active') s), '[]'::jsonb));
end;
$$;
revoke all on function system_costs_view() from public, anon;
grant execute on function system_costs_view() to authenticated;

create or replace function system_cost_item_save(p_id uuid, p_name text, p_what text, p_amount numeric, p_months int, p_status text, p_notes text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Give it a name.'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 100000 then raise exception 'Enter the amount paid.'; end if;
  if p_months is null or p_months < 1 or p_months > 240 then raise exception 'How many months does one payment cover? (1 for monthly, 12 for yearly)'; end if;
  if p_status not in ('paying', 'free', 'not_bought', 'stopped') then raise exception 'Choose a status.'; end if;
  if p_id is null then
    insert into system_cost_items (name, what, amount, months, status, notes, sort, updated_by)
    values (trim(p_name), nullif(trim(p_what), ''), p_amount, p_months, p_status, nullif(trim(p_notes), ''), coalesce((select max(sort) + 10 from system_cost_items), 10), auth.email())
    returning id into v_id;
  else
    update system_cost_items set name = trim(p_name), what = nullif(trim(p_what), ''), amount = p_amount, months = p_months, status = p_status,
           notes = nullif(trim(p_notes), ''), updated_at = now(), updated_by = auth.email() where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Not found.'; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function system_cost_item_save(uuid, text, text, numeric, int, text, text) from public, anon;
grant execute on function system_cost_item_save(uuid, text, text, numeric, int, text, text) to authenticated;
