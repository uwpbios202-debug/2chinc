-- "Under contract" is DERIVED, not typed in (Stephen, 10/12/2026): a unit is under contract while someone is getting a lease for it.
--   * a future lease exists for it, or
--   * a lease was sent to sign (sent / awaiting_agent) for an application whose unit it is, or
--   * an application is approved or on hold (for example waiting on the second adult's application) for that unit, within the last 60 days.
-- A unit with an active lease is occupied, never under contract. Applications for "any" unit do not hold a unit. Owner-managed units are ignored.
create or replace function under_contract_unit_numbers()
returns setof text
language sql stable security definer set search_path = public as $$
  select ru.unit_number
    from rental_units ru
   where ru.managed_by <> 'owner'
     and not exists (select 1 from leases l where l.unit_id = ru.id and l.status = 'active')
     and (
       exists (select 1 from leases l where l.unit_id = ru.id and l.status = 'future')
       or exists (select 1 from lease_signing_docs d join rental_applications a on a.id = d.application_id
                   where d.status in ('sent', 'awaiting_agent') and coalesce(a.applicant->'units', '[]'::jsonb) ? ru.unit_number)
       or exists (select 1 from rental_applications a
                   where a.status in ('approved', 'on_hold') and a.existing_lease_id is null
                     and a.created_at > now() - interval '60 days'
                     and coalesce(a.applicant->'units', '[]'::jsonb) ? ru.unit_number)
     );
$$;
revoke all on function under_contract_unit_numbers() from public, anon, authenticated;

-- What the public website may know: only which unit numbers are under contract, nothing about who.
create or replace function public_units_under_contract()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(u), '{}') from under_contract_unit_numbers() u;
$$;
revoke all on function public_units_under_contract() from public;
grant execute on function public_units_under_contract() to anon, authenticated;

-- Keep condo_units.occupancy (what the staff pages read) in step. Only vacant <-> under_contract moves; tenant / owner are never touched.
create or replace function sync_under_contract()
returns void
language plpgsql security definer set search_path = public as $$
begin
  update condo_units cu set occupancy = 'under_contract'
   where cu.occupancy = 'vacant' and cu.unit_number in (select under_contract_unit_numbers());
  update condo_units cu set occupancy = 'vacant'
   where cu.occupancy = 'under_contract' and cu.unit_number not in (select under_contract_unit_numbers());
end;
$$;
revoke all on function sync_under_contract() from public, anon, authenticated;

create or replace function trg_sync_under_contract()
returns trigger
language plpgsql security definer set search_path = public as $$
begin perform sync_under_contract(); return null; end;
$$;

do $$
declare t text; e text;
begin
  foreach t in array array['rental_applications', 'leases', 'lease_signing_docs'] loop
    foreach e in array array['insert', 'update', 'delete'] loop
      execute format('drop trigger if exists sync_under_contract_%s_%s on %I', e, t, t);
      execute format('create trigger sync_under_contract_%s_%s after %s on %I for each statement execute function trg_sync_under_contract()', e, t, e, t);
    end loop;
  end loop;
end $$;

-- Replaces the hand-set value from 20261112000000: Unit 18 is under contract because of its on-hold application, not because someone typed it.
update condo_units set occupancy = 'vacant' where unit_number = '18' and occupancy = 'under_contract';
select sync_under_contract();
