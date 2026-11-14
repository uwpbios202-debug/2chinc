-- Inspection photos are evidence (Stephen, 10/30/2026): contemporaneous camera photos only, no doctoring.
--   * photos can be added to, or deleted from, an inspection only while it is a draft (or not yet saved);
--     once submitted the photos are frozen, even for office staff
--   * reopening a submitted inspection is logged (who, when) on the inspection itself
-- The page also burns date, time, place and inspector into each picture and stores a SHA-256 of every photo
-- (data.items.<item>.photoMeta); the storage service records the upload time on the object.

alter table inspections add column if not exists reopen_log jsonb not null default '[]'::jsonb;

create or replace function inspection_photo_open(p_path text)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from inspections i where i.id::text = (string_to_array(p_path, '/'))[3] and i.status = 'submitted');
$$;
revoke all on function inspection_photo_open(text) from public, anon;
grant execute on function inspection_photo_open(text) to authenticated;

drop policy if exists "inspections upload own units" on storage.objects;
create policy "inspections upload own units" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'inspections' and field_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]) and inspection_photo_open(name));

drop policy if exists "inspections delete own units" on storage.objects;
create policy "inspections delete own units" on storage.objects
  for delete to authenticated
  using (bucket_id = 'inspections' and field_can_access((storage.foldername(name))[1], (storage.foldername(name))[2]) and inspection_photo_open(name));

create or replace function inspection_reopen(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r inspections;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from inspections where id = p_id;
  if not found then raise exception 'Inspection not found'; end if;
  update inspections set status = 'draft', submitted_at = null, updated_at = now(),
    reopen_log = reopen_log || jsonb_build_array(jsonb_build_object('at', now(), 'by', lower(auth.email()), 'was_submitted_at', r.submitted_at))
  where id = p_id;
  return jsonb_build_object('id', p_id, 'status', 'draft');
end;
$$;
