-- System costs, "what if we paid" (Stephen, 11/5/2026): a paid-plan price for every service, checked 11/5/2026 on the
-- services' own pricing pages. Cloudflare Pro $20 a month (billed yearly, as Stephen gave it); Supabase Pro $25 (daily backups);
-- Resend Pro $20 (50,000 emails, no daily limit); GitHub $4 per user; Twilio Verify $0.05 per code (not needed, $0);
-- Plaid has no monthly plan (pay as you go, already paid); Stripe, PayPal and Zelle have no subscription (fees per payment);
-- fonts, code libraries, the NHTSA lookup and phone alerts have no paid version.

update system_cost_items set paid_plan = 'Pro, billed yearly ($240 a year)', paid_amount = 20,
       notes = 'Free plan. Pro: $20 a month billed yearly (Stephen, 11/5/2026); $25 billed monthly.' where name = 'Cloudflare';
update system_cost_items set paid_plan = 'Pro (daily backups kept 7 days)', paid_amount = 25 where name = 'Supabase';
update system_cost_items set paid_plan = 'Pro (50,000 emails a month, no daily limit)', paid_amount = 20 where name = 'Resend';
update system_cost_items set paid_plan = 'Paid plan, 1 user', paid_amount = 4 where name = 'GitHub';
update system_cost_items set paid_plan = 'Verify: $0.05 per sign-in code (not needed: codes go by email)', paid_amount = 0 where name = 'Twilio';
update system_cost_items set paid_plan = 'No monthly plan (pay as you go, already paying)' where name = 'Plaid';
update system_cost_items set paid_plan = 'No subscription: fees per payment only', paid_amount = 0 where name in ('Stripe', 'PayPal / Venmo');
update system_cost_items set paid_plan = 'No paid version', paid_amount = 0 where name in ('Zelle', 'Google Fonts, code libraries (jsDelivr, cdnjs)', 'NHTSA vehicle lookup', 'Phone alerts (web push)');
update system_cost_items set paid_plan = 'Not needed (the site is hosted on Cloudflare)', paid_amount = 0 where name = 'Other GoDaddy products';
