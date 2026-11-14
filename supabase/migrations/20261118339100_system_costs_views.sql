-- System costs page (Stephen, 11/5/2026): the summary he asked for, a "nothing is free" view (every service on its paid plan),
-- the 12th St land contract cost by payment method with the 4% fee, and a complete list of the services the system uses
-- (checked 11/5/2026 against the code and the stored keys).
-- Paid-plan prices from public pricing pages, 11/5/2026: Supabase Pro $25/mo; Resend Pro $20/mo (50,000 emails, no daily cap);
-- Cloudflare Pro $25/mo billed monthly; GitHub Team $4 per user/mo. PayPal rent payments: 3.49% + 49c (the nonprofit rate is for donations).

alter table system_cost_items add column if not exists paid_plan text;            -- the paid plan, for the "nothing is free" view
alter table system_cost_items add column if not exists paid_amount numeric(10,2);  -- its price per month (null: same as today)
alter table system_cost_items drop constraint if exists system_cost_items_status_check;
alter table system_cost_items add constraint system_cost_items_status_check check (status in ('paying', 'free', 'not_bought', 'stopped', 'per_payment', 'no_paid_version'));

update system_cost_items set paid_plan = 'Pro (daily backups, no pausing)', paid_amount = 25 where name = 'Supabase';
update system_cost_items set paid_plan = 'Pro (50,000 emails a month, no daily cap)', paid_amount = 20 where name = 'Resend';
update system_cost_items set paid_plan = 'Pro, billed monthly ($20 a month if paid yearly)', paid_amount = 25,
       what = 'Website hosting (Pages), DNS, Turnstile anti-bot check' where name = 'Cloudflare';
update system_cost_items set paid_plan = 'Team, 1 user', paid_amount = 4 where name = 'GitHub';
update system_cost_items set paid_plan = 'Not needed', paid_amount = 0 where name = 'Twilio';
-- The "not bought yet" rows are the same plans as the Supabase and Resend lines above.
delete from system_cost_items where name in ('Supabase Pro (recommended)', 'Resend Pro') and status = 'not_bought';

insert into system_cost_items (name, what, amount, months, status, notes, sort, paid_plan, paid_amount)
select v.* from (values
  ('Stripe', 'Online rent and dues (3 accounts: 2nd Chance, Yawdcour, ROCA1)', 0::numeric, 1, 'per_payment', 'No monthly fee. Card 2.9% + 30c; bank account 0.8%, at most $5. See Stripe fees below.', 85, null::text, null::numeric),
  ('PayPal / Venmo', 'Pay button on the tenant Payments page', 0, 1, 'per_payment', 'No monthly fee. About 3.49% + 49c per rent payment (the nonprofit rate is for donations only).', 86, null, null),
  ('Zelle', 'Through the bank', 0, 1, 'free', 'No fee.', 87, 'No paid version', 0),
  ('Google Fonts, code libraries (jsDelivr, cdnjs)', 'Page lettering and small scripts', 0, 1, 'no_paid_version', 'Free; there is no paid version.', 88, 'No paid version', 0),
  ('NHTSA vehicle lookup', 'Fills year, make and model from a VIN (Parking)', 0, 1, 'no_paid_version', 'Free U.S. government service.', 89, 'No paid version', 0),
  ('Phone alerts (web push)', 'Parking alerts on phones', 0, 1, 'no_paid_version', 'Free; sent through Apple, Google and Mozilla.', 91, 'No paid version', 0)
) v(name, what, amount, months, status, notes, sort, paid_plan, paid_amount)
where not exists (select 1 from system_cost_items i where i.name = v.name);

create or replace function system_costs_view()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'what', what, 'amount', amount, 'months', months, 'status', status,
        'notes', notes, 'monthly', round(amount / months, 2), 'paid_plan', paid_plan, 'paid_amount', paid_amount,
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

drop function if exists system_cost_item_save(uuid, text, text, numeric, int, text, text);
create or replace function system_cost_item_save(p_id uuid, p_name text, p_what text, p_amount numeric, p_months int, p_status text, p_notes text,
                                                 p_paid_plan text, p_paid_amount numeric)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Give it a name.'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 100000 then raise exception 'Enter the amount paid.'; end if;
  if p_months is null or p_months < 1 or p_months > 240 then raise exception 'How many months does one payment cover? (1 for monthly, 12 for yearly)'; end if;
  if p_status not in ('paying', 'free', 'not_bought', 'stopped', 'per_payment', 'no_paid_version') then raise exception 'Choose a status.'; end if;
  if p_paid_amount is not null and (p_paid_amount < 0 or p_paid_amount > 100000) then raise exception 'Check the paid-plan price.'; end if;
  if p_id is null then
    insert into system_cost_items (name, what, amount, months, status, notes, paid_plan, paid_amount, sort, updated_by)
    values (trim(p_name), nullif(trim(p_what), ''), p_amount, p_months, p_status, nullif(trim(p_notes), ''), nullif(trim(p_paid_plan), ''), p_paid_amount,
            coalesce((select max(sort) + 10 from system_cost_items), 10), auth.email())
    returning id into v_id;
  else
    update system_cost_items set name = trim(p_name), what = nullif(trim(p_what), ''), amount = p_amount, months = p_months, status = p_status,
           notes = nullif(trim(p_notes), ''), paid_plan = nullif(trim(p_paid_plan), ''), paid_amount = p_paid_amount,
           updated_at = now(), updated_by = auth.email() where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Not found.'; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function system_cost_item_save(uuid, text, text, numeric, int, text, text, text, numeric) from public, anon;
grant execute on function system_cost_item_save(uuid, text, text, numeric, int, text, text, text, numeric) to authenticated;
