-- Repair videos (Stephen, 11/5/2026): the office can ask a tenant for a very short video (e.g. turning on a switch and nothing happens,
-- for a manufacturer's warranty), and tenants can add photos or videos to an open request.
--   maintenance_requests.videos          storage paths in bucket 'maintenance' (same folder rule as photos: <tenant id>/...)
--   maintenance_requests.video_requested_at / video_request_note   set when the office asks
--   maintenance_staff_ask_video(id, note) staff: asks, the tenant is emailed (owners copied as usual)
--   resident_request_add_media(id, path) tenant: attaches an uploaded photo or video, the office is emailed

alter table maintenance_requests add column if not exists videos text[] not null default '{}';
alter table maintenance_requests add column if not exists video_requested_at timestamptz;
alter table maintenance_requests add column if not exists video_request_note text;

update storage.buckets set file_size_limit = 52428800,   -- 50 MB: a 10-20 second phone video
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
                             'video/mp4', 'video/quicktime', 'video/webm', 'video/3gpp', 'video/x-m4v']
 where id = 'maintenance';

create or replace function resident_can_see_repair_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] in (select x::text from resident_me() x)
      or exists (select 1 from maintenance_requests r where (p_name = any(r.photos) or p_name = any(r.videos)) and resident_can_see_request(r.id));
$$;

create or replace function resident_requests() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'category', r.category, 'subject', r.subject, 'description', r.description,
      'status', r.status, 'status_label', repair_status_label(r.status), 'created_at', r.created_at, 'photos', r.photos, 'videos', r.videos,
      'video_requested_at', r.video_requested_at, 'video_request_note', r.video_request_note, 'entry_permission', r.entry_permission,
      'has_pets', r.has_pets, 'pets_note', r.pets_note, 'vendor', (select v.name from vendors v where v.id = r.vendor_id),
      'scheduled_start', r.scheduled_start, 'scheduled_end', r.scheduled_end, 'resident_confirmed_at', r.resident_confirmed_at, 'billed_amount', r.billed_amount,
      'notice_pdf', (select n.pdf_path from notices n where n.id = r.entry_notice_id),
      'updates', (select jsonb_agg(jsonb_build_object('at', u.at, 'status', u.status, 'note', u.note, 'from_resident', u.from_resident) order by u.at)
                  from maintenance_request_updates u where u.request_id = r.id and u.visible_to_resident)) order by r.created_at desc)
    from maintenance_requests r where resident_can_see_request(r.id)), '[]'::jsonb);
end;
$$;

-- Internal: ask for a video (used by the staff function, and by the office from the database).
create or replace function repair_ask_video(p_id uuid, p_note text, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests; v_note text := left(trim(coalesce(p_note, '')), 1000);
begin
  select * into r from maintenance_requests where id = p_id;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status = 'closed' then raise exception 'This request is closed.'; end if;
  if length(v_note) < 5 then raise exception 'Say what the video should show.'; end if;
  update maintenance_requests set video_requested_at = now(), video_request_note = v_note, updated_at = now() where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, note, visible_to_resident) values (p_id, p_by, 'Video requested: ' || v_note, true);
  perform repair_email_tenants(p_id, 'Repair request #' || r.number || ': please send a short video',
    '<p>For your repair request <b>' || repair_esc(r.subject) || '</b>, we need a <b>very short video</b> (10 to 20 seconds):</p>' ||
    '<p><i>' || repair_esc(v_note) || '</i></p>' ||
    '<p>How: record the video with your phone. Then open your resident portal, go to <b>Requests</b>, find this request and choose <b>Add a photo or video</b>. Pick the video and it uploads.</p>');
end;
$$;

create or replace function maintenance_staff_ask_video(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  perform repair_ask_video(p_id, p_note, auth.email());
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function resident_request_add_media(p_id uuid, p_path text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests; v_video boolean := p_path ~* '\.(mp4|mov|webm|3gp|3gpp|m4v|qt)$';
begin
  perform resident_require_current();
  if not resident_can_see_request(p_id) then raise exception 'Request not found.' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.status = 'closed' then raise exception 'This request is closed. Send a new request if the problem is back.'; end if;
  if p_path is null or split_part(p_path, '/', 1) !~ '^[0-9a-f-]{36}$' or split_part(p_path, '/', 1)::uuid not in (select resident_me())
     or not exists (select 1 from storage.objects o where o.bucket_id = 'maintenance' and o.name = p_path) then raise exception 'Bad file path'; end if;
  if p_path = any(r.photos) or p_path = any(r.videos) then return jsonb_build_object('ok', true); end if;
  if v_video and cardinality(r.videos) >= 3 then raise exception 'This request already has 3 videos.'; end if;
  if not v_video and cardinality(r.photos) >= 10 then raise exception 'This request already has 10 photos.'; end if;
  update maintenance_requests set videos = case when v_video then videos || p_path else videos end,
    photos = case when v_video then photos else photos || p_path end, updated_at = now() where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, note, from_resident)
  values (p_id, auth.email(), case when v_video then 'Added a video' else 'Added a photo' end, true);
  perform repair_email_staff(p_id, 'Tenant added a ' || case when v_video then 'video' else 'photo' end || ' to repair request #' || r.number,
    '<p>On <b>' || repair_esc(r.subject) || '</b> (' || repair_esc(coalesce(r.unit_label, '')) || ') the tenant added a ' || case when v_video then 'video' else 'photo' end ||
    '. Open the request on the Maintenance page to see it: https://2ndchinc.org/maintenance/</p>');
  return jsonb_build_object('ok', true, 'kind', case when v_video then 'video' else 'photo' end);
end;
$$;

revoke all on function repair_ask_video(uuid, text, text) from public, anon, authenticated;
grant execute on function repair_ask_video(uuid, text, text) to service_role;
revoke all on function maintenance_staff_ask_video(uuid, text), resident_request_add_media(uuid, text) from public, anon;
grant execute on function maintenance_staff_ask_video(uuid, text), resident_request_add_media(uuid, text) to authenticated, service_role;
