-- Eviction process, made air tight (Stephen, 11/12/2026: "make it air tight").
--  1. Case papers live with the case: the court's accepted papers (Electronic Filing Notice + authenticated Summons and Complaint)
--     and the process server's affidavit of service are uploaded on the Process screen (/staff/efile/?n=...&process=1) into the
--     private 'notices' bucket under case/<notice id>/..., office staff only (tenants and field staff cannot read them).
--  2. New hand step 'affidavit_ok': Claude checks every affidavit before it is filed (after the Unit 12 "#112" affidavit in May).
--  3. Steps cannot be ticked out of order: the server drops a tick whose prerequisite is missing.
--  4. The mailing (stamp) date must be a real date: not in the future, not before the notice was made, not changed after filing.
--  5. The eFile list says what is next on a filed case (serve by, affidavit, court date).
-- No new table, so no new grants.

alter table public.notices add column if not exists court_papers_path text;
alter table public.notices add column if not exists court_papers_at timestamptz;
alter table public.notices add column if not exists affidavit_path text;
alter table public.notices add column if not exists affidavit_at timestamptz;

-- Staff upload case papers (case/ folder only). Functions only in the policy, no table reads (see migration 20261118590000).
drop policy if exists "notices case staff insert" on storage.objects;
create policy "notices case staff insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'notices' and name like 'case/%' and condo_session_ok() and condo_is_staff());
drop policy if exists "notices case staff update" on storage.objects;
create policy "notices case staff update" on storage.objects for update to authenticated
  using (bucket_id = 'notices' and name like 'case/%' and condo_session_ok() and condo_is_staff());

create or replace function notice_attach_case_doc(p_id uuid, p_kind text, p_path text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_kind not in ('court_papers', 'affidavit') then raise exception 'Unknown document.'; end if;
  if p_path is null or p_path !~ ('^case/' || p_id::text || '/' || replace(p_kind, '_', '-') || '\.(pdf|jpg|png|webp)$') then raise exception 'Unexpected file name.'; end if;
  if not exists (select 1 from notices where id = p_id and case_number is not null) then raise exception 'Record the case number first.'; end if;
  if p_kind = 'court_papers' then
    update notices set court_papers_path = p_path, court_papers_at = now() where id = p_id;
  else
    -- A new affidavit must be checked again.
    update notices set affidavit_path = p_path, affidavit_at = now(),
           process_steps = process_steps - 'affidavit_ok' - 'declaration' where id = p_id;
  end if;
  return notice_process_get(p_id);
end;
$$;
revoke all on function notice_attach_case_doc(uuid, text, text) from public, anon;
grant execute on function notice_attach_case_doc(uuid, text, text) to authenticated;

create or replace function notice_process_keys()
returns text[] language sql immutable as $$
  select array['printed', 'envelope', 'label', 'gathered', 'summons', 'affidavit_ok', 'declaration', 'court', 'outcome']::text[]
$$;
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
      'case_filed_on', n.case_filed_on, 'court_at', n.court_at, 'court_place', n.court_place,
      'court_papers_path', n.court_papers_path, 'court_papers_at', n.court_papers_at, 'affidavit_path', n.affidavit_path, 'affidavit_at', n.affidavit_at,
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

-- Ticks are kept only when what they depend on is true; the first time of a tick that stays is kept.
create or replace function notice_process_save(p_id uuid, p_steps jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; n notices;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into n from notices where id = p_id and lease_id is not null;
  if n.id is null then raise exception 'Notice not found'; end if;
  select coalesce(jsonb_object_agg(k, coalesce(n.process_steps->k, jsonb_build_object('at', now(), 'by', efile_staff_name()))), '{}'::jsonb) into v
    from unnest(notice_process_keys()) k
   where coalesce((p_steps->>k)::boolean, false)
     and case k
           when 'gathered' then n.proof_path is not null
           when 'summons' then n.case_number is not null
           when 'affidavit_ok' then n.case_number is not null and n.affidavit_path is not null
           when 'declaration' then n.case_number is not null and n.affidavit_path is not null and coalesce((p_steps->>'affidavit_ok')::boolean, false)
           when 'court' then n.case_number is not null
           when 'outcome' then n.case_number is not null
           else true end;
  update notices set process_steps = v where id = p_id;
  return notice_process_get(p_id);
end;
$$;
revoke all on function notice_process_save(uuid, jsonb) from public, anon;
grant execute on function notice_process_save(uuid, jsonb) to authenticated;

-- The stamp date is the legal service date: it must be a real one.
create or replace function notice_record_service(p_id uuid, p_method text, p_served_on date, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; n notices; v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into n from notices where id = p_id;
  if n.id is null then raise exception 'Notice not found'; end if;
  if p_served_on is null then raise exception 'Enter the date stamped on the receipt.'; end if;
  if p_served_on > v_today then raise exception 'The stamp date cannot be in the future.'; end if;
  if n.sent_at is not null and p_served_on < (n.sent_at at time zone 'America/Chicago')::date then
    raise exception 'The stamp date is before this notice was made (%). Check the receipt.', to_char((n.sent_at at time zone 'America/Chicago')::date, 'FMMM/FMDD/YYYY');
  end if;
  if n.case_number is not null or n.efile_submitted_at is not null then raise exception 'This notice is already with the court; the service date cannot be changed.'; end if;
  update notices set service_method = p_method, served_on = p_served_on, service_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id;
  v := notice_after_service(p_id);
  return jsonb_build_object('ok', true) || v;
end;
$$;
revoke all on function notice_record_service(uuid, text, date, text) from public, anon;
grant execute on function notice_record_service(uuid, text, date, text) to authenticated;

-- eFile list: a filed case says what is next.
create or replace function efile_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x.j || jsonb_build_object('status', x.status, 'reason', x.reason) order by x.sent_at desc) from (
    select n.sent_at,
      jsonb_build_object('id', n.id, 'template_name', n.template_name, 'label', coalesce(u.address, l.rental_label) || ' — ' || l.tenants_label,
        'served_on', n.served_on, 'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'case_number', n.case_number, 'court_at', n.court_at,
        'submitted_at', n.efile_submitted_at, 'stops', (c->>'stops')::int, 'rent_due', (c->'type'->>'rent_due')::numeric) j,
      case when n.case_number is not null then 'filed'
           when n.efile_submitted_at is not null then 'submitted'
           when coalesce((c->>'nonpay')::boolean, false) and coalesce((c->'type'->>'rent_due')::numeric, 0) <= 0 then 'paid'
           when n.served_on is null then 'not_served'
           when n.efile_on is not null and v_today < n.efile_on then 'waiting'
           when (c->>'stops')::int > 0 then 'stop'
           else 'ready' end status,
      case when n.case_number is not null then 'Case ' || n.case_number || ' · ' ||
             case when n.process_steps ? 'outcome' then 'Closed.'
                  when n.court_at is null then 'Enter the court date.'
                  when n.court_at < now() then 'Court date passed: record the judgment or dismissal.'
                  when not n.process_steps ? 'summons' then 'Serve by ' || to_char((n.court_at at time zone 'America/Chicago')::date - 5, 'FMDay, FMMonth FMDD') || ' (at least 5 days before court).'
                  when n.affidavit_path is null then 'Waiting for the process server''s affidavit.'
                  when not n.process_steps ? 'affidavit_ok' then 'Affidavit uploaded: Claude checks it before it is filed.'
                  when not n.process_steps ? 'declaration' then 'File the affidavit with the court before ' || to_char(n.court_at at time zone 'America/Chicago', 'FMMonth FMDD') || '.'
                  else 'Court ' || to_char(n.court_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM') || '.' end
           when n.efile_submitted_at is not null then 'Submitted ' || to_char(n.efile_submitted_at at time zone 'America/Chicago', 'FMMonth FMDD') || ', waiting for the court'
           when coalesce((c->>'nonpay')::boolean, false) and coalesce((c->'type'->>'rent_due')::numeric, 0) <= 0 then 'Rent is paid. Nothing to file.'
           when n.served_on is null then 'The mailing was never recorded. Enter the certified-mail stamp date on the Notices page (or, if it was never mailed, it cannot be filed on).'
           when n.efile_on is not null and v_today < n.efile_on then 'Cure period not over. First day to file: ' || to_char(n.efile_on, 'FMDay, FMMonth FMDD')
           when (c->>'stops')::int > 0 then (select string_agg(s->>'title', '; ') from jsonb_array_elements(c->'checks') s where s->>'level' = 'stop')
           else 'No problems found. Go through the checklist.' end reason
    from notices n join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id
    cross join lateral (select efile_core(n.id) c) k
   where n.status = 'sent' and not coalesce(n.voided, false) and notice_days(n.id) is not null
     and (n.case_number is null or n.court_at is null or n.court_at > now() - interval '60 days' or not n.process_steps ? 'outcome')
     and n.sent_at > now() - interval '180 days') x), '[]'::jsonb);
end;
$$;
revoke all on function efile_list() from public, anon;
grant execute on function efile_list() to authenticated;
