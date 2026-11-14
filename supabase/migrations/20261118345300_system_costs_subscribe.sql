-- System costs, "All services subscribed" tab (Stephen, 11/5/2026): each service on its paid plan with the page where it is
-- bought, and a "Mark as subscribed" button that moves it to what we pay (status paying, the paid-plan price, monthly).
-- Nothing here buys anything: subscribing is done by a person on the service's own billing page.

alter table system_cost_items add column if not exists upgrade_url text;

update system_cost_items set upgrade_url = 'https://supabase.com/dashboard/org/jgnhyebednrbfmtpqpfq/billing' where name = 'Supabase';
update system_cost_items set upgrade_url = 'https://resend.com/settings/billing' where name = 'Resend';
update system_cost_items set upgrade_url = 'https://dash.cloudflare.com/' where name = 'Cloudflare';
update system_cost_items set upgrade_url = 'https://github.com/settings/billing' where name = 'GitHub';

create or replace function system_costs_view()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'what', what, 'amount', amount, 'months', months, 'status', status,
        'notes', notes, 'monthly', round(amount / months, 2), 'paid_plan', paid_plan, 'paid_amount', paid_amount, 'upgrade_url', upgrade_url,
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

-- After subscribing on the service's own page: record it as paid monthly at the paid-plan price.
create or replace function system_cost_mark_subscribed(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare i system_cost_items;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  select * into i from system_cost_items where id = p_id;
  if not found then raise exception 'Not found.'; end if;
  if coalesce(i.paid_amount, 0) <= 0 then raise exception 'This service has no paid plan to subscribe to.'; end if;
  update system_cost_items set status = 'paying', amount = i.paid_amount, months = 1,
         notes = coalesce(notes || ' ', '') || 'Subscribed to ' || coalesce(paid_plan, 'the paid plan') || ' on ' || to_char(now() at time zone 'America/Chicago', 'FMMM/FMDD/YYYY') || '.',
         updated_at = now(), updated_by = auth.email()
   where id = p_id;
end;
$$;
revoke all on function system_cost_mark_subscribed(uuid) from public, anon;
grant execute on function system_cost_mark_subscribed(uuid) to authenticated;
