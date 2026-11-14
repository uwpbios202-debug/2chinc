-- The Human Mirror P10-01 (found by the Phase 10 step 31 security re-check of P2-09, Stephen 11/14/2026: "yes").
-- The deletion run left the person's emails in public.email_outbox (address, subject, full body of invitations, reminders, notices),
-- and nothing purges that table. The privacy promise is that only a note that a deletion happened is kept.
--
--   * mirror.deletion_run() now also removes every outbox row of the person's Mirror emails, found through mirror.notifications.outbox_id
--     (by the person, so emails to an earlier address after an email change go too; and by their current address, the same rows the run
--     already removes from mirror.notifications). Sent or not: a reminder still waiting is not sent after the Mirror is gone.
--     Other site emails to the same address (not Mirror kinds, not linked to these records) are untouched.
--   * The deletion confirmation itself must reach the person, so it stays until it is sent. Each run first removes the confirmations of
--     earlier runs that were sent, or are over 7 days old and never sent (its record, recipient '(deleted)', keeps no address).
--   * The run returns outbox_removed as well. Everything else is unchanged from 20261119696000 (the job still reads only "queued").
-- Only mirror.email_queue writes Mirror emails to the outbox (checked 11/14/2026), and it always records outbox_id.
-- No new table. No email is sent by this migration.

create or replace function mirror.deletion_run() returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v uuid; i mirror.individuals; v_deleted int := 0; v_queued int := 0; v_status text; v_user uuid; v_note uuid; v_out int := 0; n int;
begin
  -- 0. earlier runs' deletion confirmations, once sent (or 7 days old and never sent): the outbox copy goes (P10-01)
  delete from public.email_outbox o using mirror.notifications x
    where x.recipient_email = '(deleted)' and x.outbox_id = o.id and (o.sent_at is not null or o.created_at < now() - interval '7 days');
  get diagnostics n = row_count; v_out := v_out + n;
  update mirror.notifications x set outbox_id = null
    where x.recipient_email = '(deleted)' and x.outbox_id is not null and not exists (select 1 from public.email_outbox o where o.id = x.outbox_id);

  for v in select mirror.deletion_due() loop
    select * into i from mirror.individuals where id = v for update;
    if i.id is null or i.deletion_requested_at is null then continue; end if;
    begin                                                                      -- one person at a time: a failure is retried tomorrow

    -- 1. the confirmation email, while the person (and their safety mode) still exists
    v_status := null; v_note := null; v_user := null;
    -- P10-01: the outbox copies of their Mirror emails go with the records of those emails
    delete from public.email_outbox o using mirror.notifications x
      where x.outbox_id = o.id and (x.individual_id = v or (i.auth_email is not null and x.recipient_email = i.auth_email));
    get diagnostics n = row_count; v_out := v_out + n;
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
  return jsonb_build_object('deleted', v_deleted, 'queued', v_queued, 'outbox_removed', v_out);
end $$;

revoke all on function mirror.deletion_run() from public, anon, authenticated;
grant execute on function mirror.deletion_run() to service_role;
