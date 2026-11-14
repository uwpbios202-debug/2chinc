-- The Yawdcour LLC Stripe account no longer accepts payment_method_types on Checkout; its payment methods come from a
-- payment method configuration. This one (created through Stripe's API, 10/10/2026) allows US bank accounts only.
insert into portal_settings (key, value) values ('stripe_pmc_yawdcour', 'pmc_1UOsYNLNhViU7t3UkEBRTmYM')
on conflict (key) do update set value = excluded.value;
