-- "Lease information form" for a tenant who already lives in a unit (Stephen, 11/1/2026).
-- It is filled in at https://2ndchinc.org/resident/lease-info/ after the tenant signs in, and lands in the same Applications list
-- (https://2ndchinc.org/leasing/applications/) as source 'resident', tied to the lease they already hold (existing_lease_id), so staff
-- can check the ID, approve it and build the new lease from it. No new table, so no new grants are needed.
alter table rental_applications drop constraint if exists rental_applications_source_check;
alter table rental_applications add constraint rental_applications_source_check check (source in ('site', 'on_file', 'resident'));
