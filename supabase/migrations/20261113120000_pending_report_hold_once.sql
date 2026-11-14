-- An "I've paid" report holds back the late fee and the pay-or-vacate notice for pending_hold_business_days (5).
-- A tenant could file a fresh report each time one ran out and so hold them back for good. Now, once any pending report
-- on a lease has gone stale (the hold ran out and staff have not verified it), no further pending report on that lease holds
-- anything until staff verify or reject the stale one. A card or bank payment that is still processing is unchanged.
-- New rule from today only; nothing already posted is touched.
create or replace function public.rent_unpaid(p_as_of date)
 returns table(lease_id uuid, unit_label text, address text, rent_due numeric, pending_reported numeric, tenants jsonb, account_number text, property_key text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select l.id, coalesce(u.unit_number, ''), u.address, lease_rent_due(l.id, p_as_of),
         case when exists (select 1 from payment_reports x where x.lease_id = l.id and x.status = 'pending' and not payment_report_fresh(x, p_as_of))
              then 0
              else coalesce((select sum(r.amount) from payment_reports r where r.lease_id = l.id and r.status = 'pending' and payment_report_fresh(r, p_as_of)), 0)
         end
           + coalesce((select sum(s.amount) from stripe_payments s where s.lease_id = l.id and s.status = 'processing'), 0),
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
         l.account_number, p.key
  from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
  where l.status = 'active' and lease_rent_due(l.id, p_as_of) > 0;
$function$;
