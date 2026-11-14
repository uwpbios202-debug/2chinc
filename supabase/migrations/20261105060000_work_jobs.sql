-- Work in lieu of rent, done properly (Stephen, 10/6/2026), built for Unit 4:
--   * "monthly" agreements: a standing job that earns a fixed credit every month (lawn care and snow removal, $205 a month).
--     The monthly rent cycle already posts the credit for an ACTIVE monthly agreement.
--   * "job" agreements: a one-time job with tasks and a dollar value that offsets a chosen month's rent
--     (hallway paint, the Unit 18 rent-ready job). The tenant reads and accepts the agreement, marks each task started
--     and done, and adds notes (typed or dictated) and photos. Staff inspect, then accept; accepting posts the credit
--     to the ledger once, dated the month it offsets, and emails the tenant. Nothing is credited before that.

alter table work_agreements add column if not exists kind text not null default 'monthly';
alter table work_agreements drop constraint if exists work_agreements_kind_check;
alter table work_agreements add constraint work_agreements_kind_check check (kind in ('monthly', 'job'));
alter table work_agreements add column if not exists job_value numeric(12,2);
alter table work_agreements add column if not exists credit_month date;            -- the rent month a job offsets
alter table work_agreements add column if not exists tasks jsonb not null default '[]'::jsonb;   -- [{key, name, status: todo|working|done|accepted}]
alter table work_agreements add column if not exists terms_html text;
alter table work_agreements add column if not exists worker_ack_at timestamptz;
alter table work_agreements add column if not exists worker_ack_by text;
alter table work_agreements add column if not exists accepted_at timestamptz;
alter table work_agreements add column if not exists accepted_by text;
alter table work_agreements add column if not exists credit_entry_id bigint references lease_ledger_entries(id);
alter table work_agreements add column if not exists work_location text;

create table if not exists work_notes (
  id bigint generated always as identity primary key,
  agreement_id uuid not null references work_agreements(id) on delete cascade,
  task_key text,
  author_email text not null,
  author_role text not null check (author_role in ('tenant', 'staff')),
  note text,
  via_voice boolean not null default false,
  photo_path text,
  created_at timestamptz not null default now()
);
create index if not exists work_notes_agreement_idx on work_notes (agreement_id, created_at);
alter table work_notes enable row level security;

insert into portal_settings (key, value) values ('work_alert_email', 'info@2ndchinc.org') on conflict (key) do nothing;

-- Photos of the work: private, path = <lease id>/<file>.jpg
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('work-photos', 'work-photos', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "work-photos read" on storage.objects;
create policy "work-photos read" on storage.objects for select to authenticated
  using (bucket_id = 'work-photos' and (resident_lease_ok((storage.foldername(name))[1]::uuid) or (condo_session_ok() and condo_is_staff())));
drop policy if exists "work-photos upload" on storage.objects;
create policy "work-photos upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'work-photos' and (resident_lease_ok((storage.foldername(name))[1]::uuid) or condo_is_staff()));

create or replace function work_alert(p_subject text, p_html text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_to text := coalesce(nullif((select value from portal_settings where key = 'work_alert_email'), ''), 'info@2ndchinc.org');
begin
  insert into email_outbox (to_email, subject, html, kind) values (v_to, p_subject, p_html, 'work');
end;
$$;
revoke all on function work_alert(text, text) from public, anon, authenticated;

create or replace function work_unit_label(p_lease uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce('Unit ' || ru.unit_number, ru.address, 'lease') || ' (' || l.tenants_label || ')' from leases l left join rental_units ru on ru.id = l.unit_id where l.id = p_lease;
$$;
revoke all on function work_unit_label(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tenant
create or replace function resident_work_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', w.id, 'lease_id', w.lease_id, 'title', w.title, 'kind', w.kind, 'scope', w.scope, 'status', w.status, 'monthly_credit', w.monthly_credit, 'job_value', w.job_value,
      'credit_month', w.credit_month, 'tasks', w.tasks, 'terms_html', w.terms_html, 'equipment_terms', w.equipment_terms, 'work_location', w.work_location,
      'start_date', w.start_date, 'end_date', w.end_date, 'worker_ack_at', w.worker_ack_at, 'accepted_at', w.accepted_at,
      'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'task_key', n.task_key, 'role', n.author_role, 'note', n.note, 'voice', n.via_voice, 'photo', n.photo_path, 'at', n.created_at) order by n.created_at desc)
                          from work_notes n where n.agreement_id = w.id), '[]'::jsonb),
      'credits', coalesce((select jsonb_agg(jsonb_build_object('date', e.entry_date, 'amount', -e.amount, 'description', e.description) order by e.entry_date desc)
                           from (select * from lease_ledger_entries x where x.lease_id = w.lease_id and x.kind = 'in_kind' and x.amount < 0 order by x.entry_date desc limit 12) e), '[]'::jsonb))
    order by (w.status = 'ended'), w.created_at)
    from work_agreements w where resident_lease_ok(w.lease_id) and (w.status <> 'draft' or w.kind = 'job' or w.monthly_credit is not null)), '[]'::jsonb);
end;
$$;
revoke all on function resident_work_list() from public, anon;
grant execute on function resident_work_list() to authenticated;

create or replace function resident_work_ack(p_agreement uuid, p_name text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare w work_agreements;
begin
  select * into w from work_agreements where id = p_agreement;
  if w.id is null or not resident_lease_ok(w.lease_id) then raise exception 'Agreement not found'; end if;
  if w.worker_ack_at is not null then return; end if;
  if length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Type your full name to agree'; end if;
  if not exists (select 1 from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = w.lease_id and t.id in (select resident_me())
                 and lower(t.name) like '%' || lower(split_part(trim(p_name), ' ', 1)) || '%') then raise exception 'Type your name the way it appears on your lease'; end if;
  update work_agreements set worker_ack_at = now(), worker_ack_by = trim(p_name) || ' (' || lower(auth.email()) || ')', status = 'active',
    start_date = coalesce(start_date, current_date), signed_on = current_date where id = p_agreement;
  perform work_alert('Work agreement accepted - ' || work_unit_label(w.lease_id), '<p>' || replace(trim(p_name), '<', '&lt;') || ' accepted <b>' || replace(w.title, '<', '&lt;') || '</b>.</p>');
end;
$$;
revoke all on function resident_work_ack(uuid, text) from public, anon;
grant execute on function resident_work_ack(uuid, text) to authenticated;

create or replace function resident_work_task(p_agreement uuid, p_task text, p_status text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare w work_agreements; v_tasks jsonb; v_all boolean;
begin
  select * into w from work_agreements where id = p_agreement;
  if w.id is null or not resident_lease_ok(w.lease_id) or w.kind <> 'job' then raise exception 'Agreement not found'; end if;
  if w.worker_ack_at is null then raise exception 'Read and agree to the agreement first'; end if;
  if w.accepted_at is not null then raise exception 'This job was already accepted'; end if;
  if p_status not in ('working', 'done') then raise exception 'Choose started or done'; end if;
  select jsonb_agg(case when t ->> 'key' = p_task and t ->> 'status' <> 'accepted' then jsonb_set(t, '{status}', to_jsonb(p_status)) else t end order by o) into v_tasks
    from jsonb_array_elements(w.tasks) with ordinality as x(t, o);
  update work_agreements set tasks = v_tasks where id = p_agreement;
  select bool_and(t ->> 'status' in ('done', 'accepted')) into v_all from jsonb_array_elements(v_tasks) t;
  if p_status = 'done' and v_all then
    perform work_alert('Ready for inspection - ' || work_unit_label(w.lease_id), '<p>All tasks are marked done for <b>' || replace(w.title, '<', '&lt;') || '</b> (' || work_unit_label(w.lease_id) ||
      '). Inspect it, then accept it on the staff Work page to post the credit.</p>');
  end if;
end;
$$;
revoke all on function resident_work_task(uuid, text, text) from public, anon;
grant execute on function resident_work_task(uuid, text, text) to authenticated;

create or replace function resident_work_note(p_agreement uuid, p_task text, p_note text, p_voice boolean, p_photo text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare w work_agreements;
begin
  select * into w from work_agreements where id = p_agreement;
  if w.id is null or not resident_lease_ok(w.lease_id) then raise exception 'Agreement not found'; end if;
  if coalesce(trim(p_note), '') = '' and p_photo is null then raise exception 'Write a note or add a photo'; end if;
  if p_photo is not null and p_photo not like w.lease_id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into work_notes (agreement_id, task_key, author_email, author_role, note, via_voice, photo_path)
  values (p_agreement, nullif(p_task, ''), lower(auth.email()), 'tenant', left(nullif(trim(p_note), ''), 2000), coalesce(p_voice, false), p_photo);
end;
$$;
revoke all on function resident_work_note(uuid, text, text, boolean, text) from public, anon;
grant execute on function resident_work_note(uuid, text, text, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function work_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'lease_id', w.lease_id, 'who', work_unit_label(w.lease_id), 'title', w.title, 'kind', w.kind, 'status', w.status,
      'scope', w.scope, 'monthly_credit', w.monthly_credit, 'job_value', w.job_value, 'credit_month', w.credit_month, 'tasks', w.tasks, 'worker_ack_at', w.worker_ack_at,
      'worker_ack_by', w.worker_ack_by, 'accepted_at', w.accepted_at, 'accepted_by', w.accepted_by, 'start_date', w.start_date,
      'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'task_key', n.task_key, 'role', n.author_role, 'by', n.author_email, 'note', n.note, 'voice', n.via_voice, 'photo', n.photo_path, 'at', n.created_at) order by n.created_at desc)
                          from work_notes n where n.agreement_id = w.id), '[]'::jsonb))
      order by (w.status = 'ended'), w.created_at desc) from work_agreements w), '[]'::jsonb);
end;
$$;
revoke all on function work_staff_overview() from public, anon;
grant execute on function work_staff_overview() to authenticated;

create or replace function work_staff_task(p_agreement uuid, p_task text, p_status text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_tasks jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('todo', 'working', 'done') then raise exception 'Unknown status'; end if;
  select jsonb_agg(case when t ->> 'key' = p_task and t ->> 'status' <> 'accepted' then jsonb_set(t, '{status}', to_jsonb(p_status)) else t end order by o) into v_tasks
    from work_agreements w, jsonb_array_elements(w.tasks) with ordinality as x(t, o) where w.id = p_agreement;
  update work_agreements set tasks = coalesce(v_tasks, tasks) where id = p_agreement;
end;
$$;
revoke all on function work_staff_task(uuid, text, text) from public, anon;
grant execute on function work_staff_task(uuid, text, text) to authenticated;

create or replace function work_staff_note(p_agreement uuid, p_task text, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Write the note'; end if;
  insert into work_notes (agreement_id, task_key, author_email, author_role, note) values (p_agreement, nullif(p_task, ''), lower(auth.email()), 'staff', left(trim(p_note), 2000));
end;
$$;
revoke all on function work_staff_note(uuid, text, text) from public, anon;
grant execute on function work_staff_note(uuid, text, text) to authenticated;

-- Accept a finished job after inspection: posts the credit once, dated the month it offsets, and tells the tenant.
create or replace function work_staff_accept(p_agreement uuid, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare w work_agreements; v_entry bigint; v_date date; v_first text; v_email text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into w from work_agreements where id = p_agreement for update;
  if w.id is null or w.kind <> 'job' then raise exception 'Job not found'; end if;
  if w.accepted_at is not null then raise exception 'Already accepted'; end if;
  if w.worker_ack_at is null then raise exception 'The tenant has not accepted the agreement yet'; end if;
  if coalesce(w.job_value, 0) <= 0 then raise exception 'This job has no dollar value'; end if;
  if exists (select 1 from jsonb_array_elements(w.tasks) t where t ->> 'status' not in ('done', 'accepted')) then raise exception 'Some tasks are not marked done'; end if;
  v_date := coalesce(w.credit_month, current_date);
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (w.lease_id, 'Rent Income', v_date, 'in_kind', 'Work in lieu of rent', w.title, -w.job_value, 'staff',
          'Work in lieu of rent, accepted after inspection by ' || auth.email() || ' on ' || to_char(now() at time zone 'America/Chicago', 'FMMM/FMDD/YYYY') || coalesce('. ' || nullif(trim(p_note), ''), ''))
  returning id into v_entry;
  insert into work_logs (lease_id, agreement_id, work_date, description, value, verified_by, ledger_entry_id)
  values (w.lease_id, w.id, current_date, w.title, w.job_value, lower(auth.email()), v_entry);
  update work_agreements set accepted_at = now(), accepted_by = lower(auth.email()), credit_entry_id = v_entry, status = 'ended', end_date = coalesce(end_date, current_date),
    tasks = (select coalesce(jsonb_agg(jsonb_set(t, '{status}', '"accepted"') order by o), '[]'::jsonb) from jsonb_array_elements(w.tasks) with ordinality as x(t, o)) where id = w.id;
  for v_first, v_email in select split_part(t.name, ' ', 1), t.email from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = w.lease_id and t.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (v_email, 'Your work was accepted - rent credit posted',
      '<p>Hi ' || v_first || ',</p><p>Thank you. We inspected and accepted <b>' || replace(w.title, '<', '&lt;') || '</b>. A rent credit of <b>' || to_char(w.job_value, 'FM$999,990.00') ||
      '</b> was applied to your ' || to_char(v_date, 'FMMonth YYYY') || ' rent.</p><p>2nd Chance Housing</p>', 'work');
  end loop;
  return v_entry;
end;
$$;
revoke all on function work_staff_accept(uuid, text) from public, anon;
grant execute on function work_staff_accept(uuid, text) to authenticated;
