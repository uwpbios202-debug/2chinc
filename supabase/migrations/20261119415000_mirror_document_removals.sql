-- The Human Mirror T7.4 follow-up (Stephen, 11/13/2026: "fix it"): a person's files never outlive their details.
-- The database cannot delete storage files itself (Supabase's storage.protect_delete; files must go through the Storage API). So:
--   * whenever a documents row goes away while its file is still there (above all when a whole person is removed, which cascades to
--     their documents, e.g. the 30-day deletion D-18 once it is built), the file's place is queued in mirror.document_removals;
--   * the job mirror-docs-sweep (hourly, only when there is something to do) asks the edge function mirror-files (action "sweep",
--     x-cycle-secret, the same secret as the bank-sync job, copied here from that job, never written into git) to remove them through
--     the Storage API; also any file in mirror-docs with no details left, older than a day.
-- The normal Delete button already removes the file first, then the details, so nothing is queued for it.
-- New table carries explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only; authenticated and anon none.

create table mirror.document_removals (
  path text primary key,
  queued_at timestamptz not null default now()
);
alter table mirror.document_removals enable row level security;
revoke all on mirror.document_removals from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.document_removals to service_role;

create or replace function mirror.document_queue_removal() returns trigger
language plpgsql security definer set search_path = mirror, public as $$
begin
  if mirror.document_file_exists(old.storage_path) then
    insert into mirror.document_removals (path) values (old.storage_path) on conflict (path) do nothing;
  end if;
  return old;
end $$;
create trigger documents_queue_removal after delete on mirror.documents
  for each row execute function mirror.document_queue_removal();

-- Files to remove: the queue, plus files in mirror-docs with no details, older than a day (names only; nothing is read).
create or replace function public.mirror_document_sweep_list() returns setof text
language sql stable security definer set search_path = mirror, public, storage as $$
  select r.path from mirror.document_removals r where mirror.document_file_exists(r.path)
  union
  select o.name from storage.objects o
   where o.bucket_id = 'mirror-docs' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from mirror.documents d where d.storage_path = o.name)
  limit 500;
$$;

-- After removing: clears queue entries whose file is gone. Returns how many are still waiting.
create or replace function public.mirror_document_sweep_done() returns int
language plpgsql security definer set search_path = mirror, public as $$
declare n int;
begin
  delete from mirror.document_removals r where not mirror.document_file_exists(r.path);
  select count(*) into n from public.mirror_document_sweep_list();
  return n;
end $$;

create or replace function mirror.document_sweep_needed() returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select exists (select 1 from public.mirror_document_sweep_list());
$$;

revoke all on function mirror.document_queue_removal(), public.mirror_document_sweep_list(), public.mirror_document_sweep_done(),
  mirror.document_sweep_needed() from public, anon, authenticated;
grant execute on function public.mirror_document_sweep_list(), public.mirror_document_sweep_done(), mirror.document_sweep_needed() to service_role;

-- The job: hourly at :17, calls mirror-files only when there is something to remove.
do $do$
declare v_secret text;
begin
  select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
  if v_secret is null then raise exception 'Could not find the cycle secret on the bank-sync job'; end if;
  perform cron.unschedule('mirror-docs-sweep') where exists (select 1 from cron.job where jobname = 'mirror-docs-sweep');
  perform cron.schedule('mirror-docs-sweep', '17 * * * *', format($c$
    select case when mirror.document_sweep_needed() then net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/mirror-files',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', %L), body := '{"action":"sweep"}'::jsonb) end;
  $c$, v_secret));
end;
$do$;
