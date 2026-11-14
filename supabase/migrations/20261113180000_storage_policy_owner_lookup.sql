-- Fix (10/21/2026): reading ID photos on the Applications page failed with "permission denied for function condo_owner_for_email".
-- Two storage read policies (owner-requests, violation-evidence) called condo_owner_for_email(auth.email()) directly, as the signed-in user,
-- and that function is deliberately not executable by signed-in users (it answers for any email). Postgres checks every read policy on
-- storage.objects, so any bucket's read (here: applications) could hit the error, depending on evaluation order.
-- Fix: a wrapper that only ever answers for the caller's own email, and the two policies use it.

create or replace function condo_owner_for_me() returns uuid
language sql stable security definer set search_path = public as $$
  select condo_owner_for_email(auth.email());
$$;
revoke all on function condo_owner_for_me() from public, anon;
grant execute on function condo_owner_for_me() to authenticated;

drop policy if exists "owner-requests read" on storage.objects;
create policy "owner-requests read" on storage.objects for select to authenticated
  using (bucket_id = 'owner-requests' and (((storage.foldername(name))[1])::uuid = condo_owner_for_me() or (condo_session_ok() and condo_is_staff())));

drop policy if exists "violation-evidence read" on storage.objects;
create policy "violation-evidence read" on storage.objects for select to authenticated
  using (bucket_id = 'violation-evidence' and (((storage.foldername(name))[1]) = condo_owner_for_me()::text or (condo_session_ok() and condo_is_staff())));

-- The seller documents policy read land_contract_sellers / land_contract_documents directly as the signed-in user, who has no
-- access to those tables, so any storage read could fail with "permission denied for table land_contract_sellers".
-- The check moves into a security definer function that only answers for the caller's own email.
create or replace function seller_can_read_doc(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from land_contract_documents d join land_contract_sellers s on s.contract_id = d.contract_id
                  where d.storage_path = p_path and s.active and lower(s.email) = lower(auth.email()));
$$;
revoke all on function seller_can_read_doc(text) from public, anon;
grant execute on function seller_can_read_doc(text) to authenticated;

drop policy if exists "land contract docs read seller" on storage.objects;
create policy "land contract docs read seller" on storage.objects for select to authenticated
  using (bucket_id = 'land-contract-docs' and condo_session_ok() and seller_can_read_doc(name));
