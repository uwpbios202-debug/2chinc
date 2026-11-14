-- System costs (Stephen, 11/5/2026): fill in the numbers that are known, and list the ones still needed from Stephen.
--  Verified 11/5/2026 on the official pricing pages: Supabase Pro $25/mo (daily backups 7 days); Cloudflare Pro $25/mo billed
--  monthly ($20 billed yearly); Resend Pro $20/mo (50,000 emails). GitHub: the code is in a personal account (not an
--  organization), so its paid plan is GitHub Pro, $4/mo.
--  system_cost_items.needed: what is still unknown and where Stephen gets it; the page lists these until they are cleared.

alter table system_cost_items add column if not exists needed text;

update system_cost_items set notes = 'Free plan: 32 MB of 500 MB data, 100 MB of 1 GB files (11/5/2026). No automatic backups. Pro price checked on supabase.com/pricing 11/5/2026.',
       paid_plan = 'Pro (daily backups kept 7 days, no pausing)' where name = 'Supabase';
update system_cost_items set notes = 'Free plan. Pro price checked on cloudflare.com/plans 11/5/2026.' where name = 'Cloudflare';
update system_cost_items set notes = 'Free plan (confirmed by Stephen 11/5/2026): 3,000 a month, 100 a day. About 330 a month (October 2026), busiest day 57.' where name = 'Resend';
update system_cost_items set paid_plan = 'GitHub Pro (personal account)', notes = 'Free. The code is in a personal GitHub account (private repository).' where name = 'GitHub';
update system_cost_items set notes = '$0.30 per connected bank per month x 4 (Plaid billing page, 11/5/2026). Auth, Balance and Identity are not used.' where name = 'Plaid';
update system_cost_items set notes = 'Monthly subscription (Stephen, 11/5/2026).' where name = 'Claude';

update system_cost_items set needed = 'Is the $132.84 3-year plan the Microsoft 365 email for info@2ndchinc.org? How many mailboxes, and when does it renew? Where: https://account.godaddy.com/products (sign in, then look under Email & Office).'
 where name = 'Microsoft 365 email (GoDaddy)';
update system_cost_items set needed = 'Is the $227.90 10-year plan the 2ndchinc.org registration? When does it expire? Where: https://account.godaddy.com/products (sign in, then look under Domains).'
 where name = '2ndchinc.org domain (GoDaddy)';
update system_cost_items set needed = 'Your PayPal account''s fee on a rent payment (no rent has come in by PayPal since 10/11, so $0 so far; the standard rate 3.49% + 49c is used until then). Where: https://www.paypal.com/us/business/paypal-business-fees , or the fee shown on any received payment in PayPal Activity.'
 where name = 'PayPal / Venmo';

-- Anything else billed to you that this list does not show (found by reading the GoDaddy products list).
insert into system_cost_items (name, what, amount, months, status, notes, needed, sort)
select 'Other GoDaddy products', 'Anything else GoDaddy bills (website builder, hosting, SSL, extra mailboxes)', 0, 1, 'free',
       'The website is hosted on Cloudflare, so GoDaddy hosting or website-builder plans are not needed for this system.',
       'Anything else on your GoDaddy products list besides the email and the domain? Where: https://account.godaddy.com/products', 35
 where not exists (select 1 from system_cost_items where name = 'Other GoDaddy products');

create or replace function system_costs_view()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'what', what, 'amount', amount, 'months', months, 'status', status,
        'notes', notes, 'monthly', round(amount / months, 2), 'paid_plan', paid_plan, 'paid_amount', paid_amount, 'upgrade_url', upgrade_url, 'needed', needed,
        'updated_at', updated_at, 'updated_by', updated_by) order by sort, name) from system_cost_items), '[]'::jsonb),
    'stripe', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'account', account, 'payments', payments, 'collected', collected, 'fees', fees, 'refreshed_at', refreshed_at)
        order by month desc, account) from system_cost_stripe), '[]'::jsonb),
    'whatif', coalesce((select jsonb_agg(x order by x->>'label') from (
        select jsonb_build_object('label', ru.address, 'account', coalesce(ba.stripe_account, 'main'),
               'rent', l.rent, 'share', coalesce(lease_tenant_rent(l.id), l.rent)) x
          from leases l join rental_units ru on ru.id = l.unit_id left join bank_accounts ba on ba.id = l.pay_to_account_id
         where l.status = 'active'
        union all
        select jsonb_build_object('label', 'Land contract: ' || coalesce(rp.street, ''), 'account', 'main', 'rent', lc.monthly_payment, 'share', lc.monthly_payment)
          from land_contracts lc left join rental_properties rp on rp.id = lc.property_id
         where lc.status = 'active') s), '[]'::jsonb),
    'land_contracts', coalesce((select jsonb_agg(jsonb_build_object('street', rp.street, 'monthly', lc.monthly_payment,
        'seller', (select string_agg(distinct coalesce(nullif(entity, ''), name), ', ') from land_contract_sellers s where s.contract_id = lc.id and s.active),
        'fee_pct', coalesce(nullif(condo_setting('land_contract_service_fee_pct', ''), '')::numeric, 4)))
        from land_contracts lc left join rental_properties rp on rp.id = lc.property_id where lc.status = 'active'), '[]'::jsonb));
end;
$$;
revoke all on function system_costs_view() from public, anon;
grant execute on function system_costs_view() to authenticated;

-- Stripe fees read from Stripe 11/5/2026, 12:20 PM Central.
insert into system_cost_stripe (month, account, payments, collected, fees, refreshed_at) values
  ('2026-11-01', 'main', 2, 1525.00, 44.83, now()), ('2026-10-01', 'main', 2, 1400.00, 30.93, now()),
  ('2026-11-01', 'yawdcour', 3, 2475.00, 15.00, now()), ('2026-10-01', 'yawdcour', 2, 876.00, 5.01, now()),
  ('2026-10-01', 'roca1', 2, 216.00, 1.73, now())
on conflict (month, account) do update set payments = excluded.payments, collected = excluded.collected, fees = excluded.fees, refreshed_at = excluded.refreshed_at;
