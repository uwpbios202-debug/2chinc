-- A third Stripe account for ROCA1 (Stephen, 10/10/2026): association dues and unit 16's rent are ROCA1's money and pay out to
-- ROCA1's First Citizens account, never 2nd Chance's. Both stay OFF until Stripe approves the account and a $1 test passes.
--   bank_accounts.stripe_account        'roca1' for first_citizens_roca1 (unit 16's lease routes there)
--   stripe_owner_customers.stripe_account  which Stripe account an owner's customer lives in ('main' = old, 'roca1')
--   portal_settings stripe_enabled_roca1   master switch for the account (tenant Pay online AND owner dues server check)
--   portal_settings owner_pay_stripe       shows the owner "Pay from your bank account" card (stays off)
alter table bank_accounts add column if not exists stripe_account text;
update bank_accounts set stripe_account = 'roca1' where bank_key = 'first_citizens_roca1';
alter table stripe_owner_customers add column if not exists stripe_account text not null default 'main';
insert into portal_settings (key, value) values ('stripe_enabled_roca1', 'off') on conflict (key) do nothing;
