-- Process screen for a served-to-be eviction notice (Stephen, 11/12/2026): on /staff/efile/ a notice that is not mailed yet (or whose
-- cure period is still running) opens a "Processing" screen with the steps checked off one by one: print the notice (Albert signs),
-- print the envelope, affix the Certified Mail label, mail it (records the stamp date = legal service), upload the stamped receipt,
-- gather the 3 court documents. The hand steps are saved in notices.process_steps; "mailed" and "receipt uploaded" come from the
-- recorded service and the stored receipt. No new table (column + functions), so no new grants are needed.

alter table public.notices add column if not exists process_steps jsonb not null default '{}'::jsonb;

create or replace function notice_process_keys()
returns text[] language sql immutable as $$ select array['printed', 'envelope', 'label', 'gathered']::text[] $$;
revoke all on function notice_process_keys() from public, anon;
grant execute on function notice_process_keys() to authenticated, service_role;

create or replace function notice_process_get(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'sent_at', n.sent_at,
      'label', coalesce(u.address, l.rental_label) || ' — ' || l.tenants_label, 'unit', u.unit_number,
      'pdf_path', n.pdf_path, 'proof_path', n.proof_path, 'served_on', n.served_on, 'service_method', n.service_method, 'service_note', n.service_note,
      'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'case_number', n.case_number, 'steps', n.process_steps,
      'rent_due', lease_rent_due(n.lease_id, current_date), 'days', notice_days(n.id))
    into r
    from notices n join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id
   where n.id = p_id and n.status = 'sent' and not coalesce(n.voided, false);
  if r is null then raise exception 'Notice not found'; end if;
  return r;
end;
$$;
revoke all on function notice_process_get(uuid) from public, anon;
grant execute on function notice_process_get(uuid) to authenticated;

create or replace function notice_process_save(p_id uuid, p_steps jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select coalesce(jsonb_object_agg(k, jsonb_build_object('at', now(), 'by', efile_staff_name())), '{}'::jsonb) into v
    from unnest(notice_process_keys()) k where coalesce((p_steps->>k)::boolean, false);
  -- keep the original time of a step that was already ticked
  select coalesce(jsonb_object_agg(e.key, coalesce(n.process_steps->e.key, e.value)), '{}'::jsonb) into v
    from jsonb_each(v) e cross join (select process_steps from notices where id = p_id) n;
  update notices set process_steps = v where id = p_id and lease_id is not null;
  if not found then raise exception 'Notice not found'; end if;
  return notice_process_get(p_id);
end;
$$;
revoke all on function notice_process_save(uuid, jsonb) from public, anon;
grant execute on function notice_process_save(uuid, jsonb) to authenticated;
