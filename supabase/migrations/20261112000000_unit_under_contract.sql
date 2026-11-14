-- Adds an 'under_contract' occupancy for a unit that has an accepted offer / signed contract but has not closed or moved in.
alter table condo_units drop constraint if exists condo_units_occupancy_check;
alter table condo_units add constraint condo_units_occupancy_check
  check (occupancy in ('owner', 'tenant', 'vacant', 'under_contract'));

update condo_units set occupancy = 'under_contract' where unit_number = '18';
