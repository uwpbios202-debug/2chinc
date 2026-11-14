-- System costs (Stephen, 11/5/2026: "You have those numbers now, build it"). The amounts Stephen gave are taken as given;
-- nothing is asked of him. system_cost_items.needed now holds where a figure comes from when Claude cannot see that account
-- (no access to its billing), so the page can show which numbers are Stephen's and which Claude read itself.

update system_cost_items set notes = '$132.84 for 3 years (Stephen, 11/5/2026).',
       needed = 'GoDaddy account: the $132.84 3-year amount is as Stephen gave it; what it covers, the number of mailboxes and the renewal date are in GoDaddy.'
 where name = 'Microsoft 365 email (GoDaddy)';
update system_cost_items set notes = '$227.90 for 10 years (Stephen, 11/5/2026).',
       needed = 'GoDaddy account: the $227.90 10-year amount is as Stephen gave it; the expiry date is in GoDaddy.'
 where name = '2ndchinc.org domain (GoDaddy)';
update system_cost_items set needed = 'GoDaddy account: anything else GoDaddy bills is not visible to Claude (counted as $0).'
 where name = 'Other GoDaddy products';
update system_cost_items set needed = 'PayPal account: the rate is PayPal''s standard 3.49% + 49c; no rent has come in by PayPal since 10/11/2026, so $0 so far.'
 where name = 'PayPal / Venmo';
update system_cost_items set needed = 'Claude billing: $20 a month as Stephen gave it.' where name = 'Claude';
update system_cost_items set needed = 'Plaid invoices: $0.30 x 4 banks from the Plaid billing page Stephen showed; the invoices themselves are in the Plaid dashboard.' where name = 'Plaid';
update system_cost_items set needed = 'Cloudflare billing: the free plan is read from the site settings; the billing page itself is not visible to Claude.' where name = 'Cloudflare';
update system_cost_items set needed = 'Resend billing: free plan as Stephen confirmed (the key Claude has can only send).' where name = 'Resend';
update system_cost_items set needed = 'GitHub billing: free, read from the account type; the billing page is not visible to Claude.' where name = 'GitHub';
