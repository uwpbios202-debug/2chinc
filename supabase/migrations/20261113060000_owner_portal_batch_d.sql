-- Owner portal fixes, batch D (Stephen, 10/13/2026): self-service and content.
--   1. An owner can attach photos or a PDF to a hearing request (private bucket, the owner's own folder; staff can read them).
--   2. An owner sees the board vote that came from their request (number and status only, never the vote text).
--   3. The change-log label for the mobile number no longer says "sign-in texts".
-- Only functions, one column and one bucket are added: no existing row is changed.

-- ---------------------------------------------------------------------------
-- 1. Hearing evidence.
alter table condo_violations add column if not exists hearing_evidence text[] not null default '{}';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('violation-evidence', 'violation-evidence', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;
drop policy if exists "violation-evidence upload" on storage.objects;
create policy "violation-evidence upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'violation-evidence' and (storage.foldername(name))[1] = condo_owner_for_email(auth.email())::text);
drop policy if exists "violation-evidence read" on storage.objects;
create policy "violation-evidence read" on storage.objects for select to authenticated
  using (bucket_id = 'violation-evidence' and ((storage.foldername(name))[1] = condo_owner_for_email(auth.email())::text or (condo_session_ok() and condo_is_staff())));

-- The hearing request now takes optional evidence. Built from the live function so nothing else about it changes.
do $do$
declare v text := pg_get_functiondef('roca_violation_request_hearing(bigint, text)'::regprocedure);
  v_h_old text := $o$roca_violation_request_hearing(p_id bigint, p_note text)$o$;
  v_h_new text := $n$roca_violation_request_hearing(p_id bigint, p_note text, p_evidence text[] DEFAULT '{}'::text[])$n$;
  v_c_old text := $o$if length(coalesce(trim(p_note), '')) < 10 then$o$;
  v_c_new text := $n$if coalesce(array_length(p_evidence, 1), 0) > 3 then raise exception 'You can attach up to 3 files.'; end if;
  if exists (select 1 from unnest(coalesce(p_evidence, '{}')) ph where ph not like condo_owner_for_email(auth.email())::text || '/%' or ph like '%..%') then raise exception 'Bad file path'; end if;
  if length(coalesce(trim(p_note), '')) < 10 then$n$;
  v_u_old text := $o$hearing_request_note = trim(p_note),$o$;
  v_u_new text := $n$hearing_request_note = trim(p_note), hearing_evidence = coalesce(p_evidence, '{}'),$n$;
begin
  if position(v_h_old in v) = 0 or position(v_c_old in v) = 0 or position(v_u_old in v) = 0 then raise exception 'roca_violation_request_hearing changed: cannot patch'; end if;
  execute replace(replace(replace(v, v_h_old, v_h_new), v_c_old, v_c_new), v_u_old, v_u_new);
end $do$;
drop function if exists roca_violation_request_hearing(bigint, text);
revoke all on function roca_violation_request_hearing(bigint, text, text[]) from public, anon;
grant execute on function roca_violation_request_hearing(bigint, text, text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. A request that went to the board: the owner sees the resolution's number and status.
do $do$
declare v text := pg_get_functiondef('owner_requests_mine()'::regprocedure);
  v_old text := $o$'status', r.status, 'response', r.response,$o$;
  v_new text := $n$'status', r.status, 'response', r.response,
        'board', (select jsonb_build_object('number', x.number, 'status', x.status) from roca_resolutions x where x.id = r.resolution_id),$n$;
begin
  if position(v_old in v) = 0 then raise exception 'owner_requests_mine changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;

-- ---------------------------------------------------------------------------
-- 3. Label (it is stored in each profile change as it was written; new changes use the new label).
do $do$
declare v text := pg_get_functiondef('condo_owner_editable_fields()'::regprocedure);
  v_old text := $o$Mobile phone (sign-in texts)$o$;
  v_new text := $n$Mobile phone$n$;
begin
  if position(v_old in v) = 0 then raise exception 'condo_owner_editable_fields changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;

-- ---------------------------------------------------------------------------
-- 4. Staff can add a repair to the board's priority list (it was a one-time seed). Owners see it on their Requests tab.
create or replace function roca_priority_staff_add(p_rank text, p_sort numeric, p_title text, p_estimate numeric, p_detail text, p_urgent boolean)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_rank, ''))) = 0 or p_sort is null or length(trim(coalesce(p_title, ''))) < 3 then raise exception 'Give the rank, the order number and a title.'; end if;
  insert into roca_repair_priorities (rank_label, sort, title, estimate, detail, urgent)
  values (trim(p_rank), p_sort, trim(p_title), p_estimate, nullif(trim(coalesce(p_detail, '')), ''), coalesce(p_urgent, false)) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function roca_priority_staff_add(text, numeric, text, numeric, text, boolean) from public, anon;
grant execute on function roca_priority_staff_add(text, numeric, text, numeric, text, boolean) to authenticated;
