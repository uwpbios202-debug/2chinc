-- Tenant credit/debit cards (Stephen, 10/11/2026): tenants want card rewards. A card is accepted only with 3D Secure, the billing
-- name and address, and a written authorization on the pay button; the Stripe webhook checks the cardholder name against the lease
-- and refunds a card that is not a tenant's (a parent's or friend's card is how chargebacks happen).
-- tenant_cards is OFF until Stephen switches it on:  update portal_settings set value = 'on' where key = 'tenant_cards';
-- Autopay stays bank-only. Cards cost 2nd Chance about 2.9% + 30 cents; a bank payment costs under $5.
insert into portal_settings (key, value) values ('tenant_cards', 'off') on conflict (key) do nothing;
insert into portal_settings (key, value) values
  ('stripe_pmc_card_yawdcour', 'pmc_1UPDIWLNhViU7t3UvBHLiVoY'),   -- bank or card, no wallets; made through Stripe's API 10/11/2026
  ('stripe_pmc_card_roca1',    'pmc_1UPDIXLU88c7pvW3XPFr8BOc')
on conflict (key) do update set value = excluded.value;

-- Evidence kept with each online payment (for a dispute): who paid and with what.
alter table stripe_payments add column if not exists payer_name text;
alter table stripe_payments add column if not exists card_brand text;
alter table stripe_payments add column if not exists card_last4 text;
alter table stripe_payments add column if not exists name_check text;   -- match | mismatch | missing (cards only)
