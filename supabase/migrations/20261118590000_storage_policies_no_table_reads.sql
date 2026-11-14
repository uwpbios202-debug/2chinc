-- Fix (problem report 10A67792, 11/8/2026): every storage upload AND read by a signed-in user failed in every bucket with
-- "permission denied for table parking_alerts". Postgres checks the table privileges of every policy on storage.objects,
-- and three policies read tables signed-in users may not read (parking_alerts from 20261118440000, parking_acks from
-- 20261118530000). Same kind of bug as 10/21 (20261113180000). The policies now call security definer helpers instead.
-- Rule: a storage.objects policy never reads a table directly unless `authenticated` can select it.

create or replace function storage_parking_alert_photo_ok(p_name text, p_upload boolean)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from parking_alerts a
                  where a.id::text = (storage.foldername(p_name))[1]
                    and a.reporter_email = lower(auth.email())
                    and (not p_upload or a.status in ('open', 'tow_requested')));
$$;
revoke all on function storage_parking_alert_photo_ok(text, boolean) from public, anon;
grant execute on function storage_parking_alert_photo_ok(text, boolean) to authenticated;

create or replace function storage_parking_ack_scan_mine(p_name text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from parking_acks a where a.scan_path = p_name and lower(a.email) = lower(auth.email()));
$$;
revoke all on function storage_parking_ack_scan_mine(text) from public, anon;
grant execute on function storage_parking_ack_scan_mine(text) to authenticated;

drop policy if exists "parking alert photos upload reporter" on storage.objects;
create policy "parking alert photos upload reporter" on storage.objects for insert to authenticated
  with check (bucket_id = 'parking-alerts' and storage_parking_alert_photo_ok(name, true));

drop policy if exists "parking alert photos read reporter or staff" on storage.objects;
create policy "parking alert photos read reporter or staff" on storage.objects for select to authenticated
  using (bucket_id = 'parking-alerts' and (condo_is_staff() or storage_parking_alert_photo_ok(name, false)));

drop policy if exists "parking acks paper read signer" on storage.objects;
create policy "parking acks paper read signer" on storage.objects for select to authenticated
  using (bucket_id = 'parking-acks' and (storage.foldername(name))[1] = 'paper' and storage_parking_ack_scan_mine(name));
