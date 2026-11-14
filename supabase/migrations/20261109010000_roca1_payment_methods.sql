-- ROCA1's Stripe account: bank-only payment method configuration (created through Stripe's API, 10/11/2026; US bank accounts
-- only, no cards), the same way as Yawdcour's. stripe-pay reads portal_settings stripe_pmc_<account>.
insert into portal_settings (key, value) values ('stripe_pmc_roca1', 'pmc_1UPCebLU88c7pvW34rxZWIuN')
on conflict (key) do update set value = excluded.value;
