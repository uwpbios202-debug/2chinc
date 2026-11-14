-- The Human Mirror P2-09 (Phase 9, handoff step 28, the last Phase 9 step): the deletion run after the 30 days (D-18, D-45).
-- A person asks to delete their Mirror in Settings (mirror_my_deletion); they can cancel for 30 days. Until now nothing deleted it.
--
--   * mirror.deletion_run(): every person whose request is 30 days old (by Milwaukee date: asked on 11/1, deleted on or after 12/1, the
--     date Settings shows) is deleted. Their Mirror goes with them: every table that belongs to a person is linked to mirror.individuals
--     "on delete cascade" (35 tables; the "never change" guards on answers, notes, saved Daily Numbers, need history and finished
--     check-ins already let a whole-Mirror deletion through). Their uploaded files are queued for removal by the existing trigger on
--     mirror.documents, and the hourly mirror-docs-sweep job removes them from storage.
--   * Also removed: their display settings (mirror.profiles), the record of emails sent to them (mirror.notifications), their counters
--     (mirror.rate_counts), and their sign-in account when that email signs in to nothing else (no 2nd Chance portal login, no
--     organization membership).
--   * The audit log keeps only that it happened (Settings and the privacy page promise "a note that a deletion happened is kept, without
--     any of your information"): their rows keep ids, actions and dates; the person's own email and every written reason on their rows
--     are cleared. That is the one change the append-only audit log allows, and only inside this run (setting mirror.redact_individual).
--     One new row: action 'deleted' (system, ids only).
--   * Kept, because they are not the Mirror: a Navigator's own record of the person (nav_referrals; its link to the Mirror is cleared)
--     and referral copies a program or the office already received (chpms_referrals).
--   * Before deleting, one confirmation email to their address (kind mirror_security, neutral wording in safety mode), through
--     mirror.email_queue, so it is held while that kind is off (Stephen turns it on). The record of that email keeps no address.
--   * Job mirror-deletions: daily at 14:15 UTC (8:15 Milwaukee), calls outbox-flush only when an email was really queued (the
--     x-cycle-secret is copied from the bank-sync job, never written into git), like mirror-reminders.
-- No new table. Nobody is due today (the only Mirror on live, Stephen's trial, has no request), so the first run deletes nothing.

-- The audit log stays append-only, except the redaction done by the deletion run for the person being deleted.
create or replace function mirror.audit_no_change() returns trigger
language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'UPDATE' and old.individual_id is not null
     and coalesce(current_setting('mirror.redact_individual', true), '') = old.individual_id::text
     and (new.id, new.at, new.actor_role, new.organization_id, new.individual_id, new.action, new.category, new.table_name, new.row_id)
         is not distinct from (old.id, old.at, old.actor_role, old.organization_id, old.individual_id, old.action, old.category, old.table_name, old.row_id)
     and (new.actor_email is null or new.actor_email is not distinct from old.actor_email)
     and new.reason is null then
    return new;                                                                -- P2-09: clear the deleted person's email and reasons only
  end if;
  raise exception 'The Mirror audit log cannot be changed or deleted.' using errcode = '42501';
end $$;

-- People due for deletion today (Milwaukee date).
create or replace function mirror.deletion_due() returns setof uuid
language sql stable security definer set search_path = mirror, public as $$
  select i.id from mirror.individuals i
  where i.deletion_requested_at is not null
    and (i.deletion_requested_at at time zone 'America/Chicago')::date + 30 <= (now() at time zone 'America/Chicago')::date;
$$;

-- The run. Returns {deleted, queued}. Only the job (postgres) and service_role call it.
create or replace function mirror.deletion_run() returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v uuid; i mirror.individuals; v_deleted int := 0; v_queued int := 0; v_status text; v_user uuid; v_note uuid;
begin
  for v in select mirror.deletion_due() loop
    select * into i from mirror.individuals where id = v for update;
    if i.id is null or i.deletion_requested_at is null then continue; end if;
    begin                                                                      -- one person at a time: a failure is retried tomorrow

    -- 1. the confirmation email, while the person (and their safety mode) still exists
    v_status := null; v_note := null; v_user := null;
    if i.auth_email is not null then
      delete from mirror.notifications where individual_id = v or recipient_email = i.auth_email;
      v_status := mirror.email_queue(i.auth_email, 'mirror_security',
        jsonb_build_object('first_name', i.preferred_name, 'reason', 'your Human Mirror was deleted, as you asked 30 days ago',
                           'ref', 'deleted:' || v), v);
      select id into v_note from mirror.notifications where individual_id = v and kind = 'mirror_security' order by created_at desc limit 1;
    else
      delete from mirror.notifications where individual_id = v;
    end if;

    -- 2. the audit log keeps only that it happened
    perform set_config('mirror.redact_individual', v::text, true);
    update mirror.audit_logs set actor_email = case when actor_email = i.auth_email then null else actor_email end, reason = null
      where individual_id = v and (reason is not null or actor_email = i.auth_email);
    perform set_config('mirror.redact_individual', '', true);
    insert into mirror.audit_logs (actor_email, actor_role, organization_id, individual_id, action, category, table_name, row_id, reason)
    values (null, 'system', null, v, 'deleted', 'general', 'individuals', v::text, null);

    -- 3. the Mirror itself (cascades to every table of the person; files are queued for the hourly sweep)
    delete from mirror.individuals where id = v;
    if i.auth_email is not null then
      delete from mirror.profiles where auth_email = i.auth_email;
      delete from mirror.rate_counts where actor_email = i.auth_email;
      update mirror.notifications set recipient_email = '(deleted)' where id = v_note;
      if not coalesce(public.condo_email_on_file(i.auth_email), false)
         and not exists (select 1 from mirror.organization_members m where m.auth_email = i.auth_email)
         and not exists (select 1 from mirror.platform_admins p where p.auth_email = i.auth_email) then
        select id into v_user from auth.users where lower(email) = i.auth_email;
        if v_user is not null then
          begin delete from auth.users where id = v_user;
          exception when others then delete from auth.sessions where user_id = v_user; end;   -- account kept if something else needs it; signed out
        end if;
      end if;
    end if;
    v_deleted := v_deleted + 1;
    if v_status = 'queued' then v_queued := v_queued + 1; end if;
    exception when others then
      insert into mirror.audit_logs (actor_role, individual_id, action, category, table_name, row_id, reason)
      values ('system', v, 'deletion_failed', 'general', 'individuals', v::text, 'error ' || sqlstate);
    end;
  end loop;
  return jsonb_build_object('deleted', v_deleted, 'queued', v_queued);
end $$;

revoke all on function mirror.deletion_due(), mirror.deletion_run() from public, anon, authenticated;
grant execute on function mirror.deletion_due(), mirror.deletion_run() to service_role;

-- The job: daily; calls outbox-flush only when a confirmation was really queued.
do $j$
declare v_secret text;
begin
  select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
  if v_secret is null then raise exception 'Could not find the cycle secret on the bank-sync job'; end if;
  perform cron.unschedule('mirror-deletions') where exists (select 1 from cron.job where jobname = 'mirror-deletions');
  perform cron.schedule('mirror-deletions', '15 14 * * *', format($c$
    select case when (mirror.deletion_run() ->> 'queued')::int > 0 then net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', %L), body := '{}'::jsonb) end;
  $c$, v_secret));
end $j$;
