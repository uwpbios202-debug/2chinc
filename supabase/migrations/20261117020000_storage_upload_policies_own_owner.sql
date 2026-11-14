-- Fix (10/31/2026): saving an inspection photo failed with "permission denied for function condo_owner_for_email".
-- The 10/21 fix (20261113180000) repaired the two READ policies; the matching INSERT policies for owner-requests and
-- violation-evidence still called condo_owner_for_email(auth.email()) directly as the signed-in user, who may not run it.
-- Postgres checks every insert policy on storage.objects, so an upload to any bucket (here: inspections) could hit the error.
-- Same fix: both policies use condo_owner_for_me(), which only answers for the caller's own email. Rules are unchanged.

drop policy if exists "owner-requests upload" on storage.objects;
create policy "owner-requests upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'owner-requests' and (((storage.foldername(name))[1])::uuid = condo_owner_for_me()));

drop policy if exists "violation-evidence upload" on storage.objects;
create policy "violation-evidence upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'violation-evidence' and ((storage.foldername(name))[1] = condo_owner_for_me()::text));
