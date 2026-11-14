-- !! RULE (Stephen 10/5/2026): owners (ROCA1 dues) and tenants (2nd Chance rent) have SEPARATE
-- !! bank accounts. They share one PayPal button here for now; give owners their own button
-- !! under the ROCA1 account and replace the two owner_pay_paypal_* values (see ROADMAP.md).
-- PayPal / Venmo hosted button (public client id + public button id), shown to
-- owners and to tenants. Both use the same button for now; to give owners
-- (ROCA1's dues) their own PayPal account, change only the owner_pay_* values.
insert into portal_settings (key, value) values
  ('pay_paypal_client_id', 'BAACd0EpsTu54qDwuH3Xori4DsWjKasCmUKuGzM6KgKvyko2iJmyRQsacND6m3mm6I0OprQMgaMpDR8c-s'),
  ('pay_paypal_hosted_id', '26N8KZLMKXKN2'),
  ('owner_pay_paypal_client_id', 'BAACd0EpsTu54qDwuH3Xori4DsWjKasCmUKuGzM6KgKvyko2iJmyRQsacND6m3mm6I0OprQMgaMpDR8c-s'),
  ('owner_pay_paypal_hosted_id', '26N8KZLMKXKN2')
on conflict (key) do update set value = excluded.value;
