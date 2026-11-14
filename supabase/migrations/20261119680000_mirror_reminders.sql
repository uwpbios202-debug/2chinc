-- The Human Mirror Phase 9, handoff step 25: T9.2 reminders (appointments and plan steps) through the existing cron pattern.
--   * mirror.send_reminders(): once a day, the day BEFORE: every scheduled appointment starting tomorrow (Milwaukee date) and every open
--     plan step due tomorrow gets one reminder to the person's own sign-in email, through mirror.email_queue (T9.1). So the person's
--     choices in Settings (appointment reminders, reminders about the plan), safety mode (no reminders at all) and Stephen's hold (each
--     kind off until he turns it on) all apply. The email names only the date and time, never the title, place or topic (D-17, D-42).
--     A moved appointment or step gets a new reminder (the reference includes the date); the same one is never sent twice.
--     People without their own sign-in email get none (their coordinator works with them directly).
--   * Job mirror-reminders, every day at 13:30 UTC (7:30 a.m. Milwaukee in winter, 8:30 in summer): runs it, and only when something was
--     really queued it calls outbox-flush with x-cycle-secret (copied here from the bank-sync job, never written into git), as
--     repair-heat-escalate does.
-- Times use Milwaukee time (set timezone, P8-01). No new table.

create or replace function mirror.send_reminders() returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare x record; s text; v_held int := 0; v_queued int := 0; v_skipped int := 0; v_tomorrow date := current_date + 1;
begin
  for x in
    select a.id, a.starts_at, i.id as ind, i.auth_email, i.preferred_name
      from mirror.appointments a join mirror.individuals i on i.id = a.individual_id
     where a.status = 'scheduled' and a.starts_at::date = v_tomorrow and i.auth_email is not null
  loop
    s := mirror.email_queue(x.auth_email, 'mirror_appointment',
      jsonb_build_object('first_name', x.preferred_name, 'when', trim(to_char(x.starts_at, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')),
                         'ref', 'appt:' || x.id || ':' || to_char(x.starts_at, 'YYYY-MM-DD"T"HH24:MI')), x.ind);
    v_held := v_held + (s = 'held')::int; v_queued := v_queued + (s = 'queued')::int; v_skipped := v_skipped + (s = 'skipped')::int;
  end loop;
  for x in
    select t.id, t.due_on, i.id as ind, i.auth_email, i.preferred_name
      from mirror.action_items t join mirror.individuals i on i.id = t.individual_id
     where t.status = 'open' and t.due_on = v_tomorrow and i.auth_email is not null
  loop
    s := mirror.email_queue(x.auth_email, 'mirror_action',
      jsonb_build_object('first_name', x.preferred_name, 'when', 'due ' || trim(to_char(x.due_on, 'FMDay, FMMonth FMDD')),
                         'ref', 'action:' || x.id || ':' || x.due_on), x.ind);
    v_held := v_held + (s = 'held')::int; v_queued := v_queued + (s = 'queued')::int; v_skipped := v_skipped + (s = 'skipped')::int;
  end loop;
  return jsonb_build_object('held', v_held, 'queued', v_queued, 'skipped', v_skipped);
end $$;

revoke all on function mirror.send_reminders() from public, anon, authenticated;
grant execute on function mirror.send_reminders() to service_role;

-- The job: daily; calls outbox-flush only when a reminder was really queued.
do $do$
declare v_secret text;
begin
  select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
  if v_secret is null then raise exception 'Could not find the cycle secret on the bank-sync job'; end if;
  perform cron.unschedule('mirror-reminders') where exists (select 1 from cron.job where jobname = 'mirror-reminders');
  perform cron.schedule('mirror-reminders', '30 13 * * *', format($c$
    select case when (mirror.send_reminders() ->> 'queued')::int > 0 then net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', %L), body := '{}'::jsonb) end;
  $c$, v_secret));
end;
$do$;
