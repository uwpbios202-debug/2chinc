-- Once a lease is signed, the unit no longer appears on the landing page (Stephen, 11/6/2026).
-- "Signed" = the unit has an active or future lease. Exception: an active lease whose tenant is moving out
-- (a move_outs row not yet closed) does not hide the unit, so it can be listed again before they leave.
-- A future lease always hides it (the next tenant has signed). Units in progress (signing sent, application
-- approved) stay "Under contract" as before (public_units_under_contract).
-- The public site learns only unit numbers, nothing about who. No new table.

create or replace function public_units_leased()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct ru.unit_number), '{}')
    from rental_units ru
   where ru.managed_by <> 'owner'
     and (exists (select 1 from leases l where l.unit_id = ru.id and l.status = 'future')
          or exists (select 1 from leases l where l.unit_id = ru.id and l.status = 'active'
                       and not exists (select 1 from move_outs m where m.lease_id = l.id and m.status <> 'closed')));
$$;
revoke all on function public_units_leased() from public;
grant execute on function public_units_leased() to anon, authenticated;
