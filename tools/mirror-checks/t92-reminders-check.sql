-- Mirror T9.2 check: the day-before reminders for appointments and plan steps, through the T9.1 queue (choices, safety mode, the hold).
-- Fictional people; always rolled back (no email is sent).
do $chk$
declare
  r text[] := '{}'; a uuid; b uuid; c uuid; ap uuid; j jsonb; ok boolean; n0 int; n1 int; v_tom timestamptz;
begin
  v_tom := ((now() at time zone 'America/Chicago')::date + 1 + time '10:00') at time zone 'America/Chicago';
  insert into mirror.individuals (auth_email, preferred_name) values ('check.ra1@example.invalid', 'Ray') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name, safety_sensitive) values ('check.ra2@example.invalid', 'Sam', true) returning id into b;
  insert into mirror.individuals (preferred_name) values ('No Email') returning id into c;
  insert into mirror.appointments (individual_id, title, starts_at, status, category, created_by, created_by_role)
    values (a, 'Dentist at the clinic', v_tom, 'scheduled', 'health', 'check', 'self') returning id into ap;
  insert into mirror.appointments (individual_id, title, starts_at, status, category, created_by, created_by_role)
    values (a, 'Later one', v_tom + interval '5 days', 'scheduled', 'general', 'check', 'self'),
           (a, 'Cancelled one', v_tom, 'cancelled', 'general', 'check', 'self'),
           (b, 'Safety person', v_tom, 'scheduled', 'general', 'check', 'self'),
           (c, 'No email person', v_tom, 'scheduled', 'general', 'check', 'self');
  insert into mirror.action_items (individual_id, title, due_on, status, category, added_by, added_by_role)
    values (a, 'Call the landlord', (now() at time zone 'America/Chicago')::date + 1, 'open', 'general', 'check', 'self');
  insert into mirror.action_items (individual_id, title, due_on, status, done_at, category, added_by, added_by_role)
    values (a, 'Done already', (now() at time zone 'America/Chicago')::date + 1, 'done', now(), 'general', 'check', 'self');
  select count(*) into n0 from public.email_outbox;

  -- 1. with the kinds off: tomorrow's appointment and step are recorded as held; nothing sent; others not reminded
  update portal_settings set value = '' where key = 'mirror_email_kinds_enabled';
  j := mirror.send_reminders();
  select count(*) into n1 from public.email_outbox;
  ok := (j ->> 'held')::int = 2 and (j ->> 'queued')::int = 0 and n1 = n0
    and not exists (select 1 from mirror.notifications where individual_id = c)
    and not exists (select 1 from mirror.notifications where individual_id = b and not (status = 'skipped' and reason = 'safety mode'))
    and exists (select 1 from mirror.notifications where individual_id = b);
  r := r || format('1 off: tomorrow''s appointment and step held (%s), safety mode and no-email skipped or ignored, nothing sent: %s', j, ok);

  -- 2. turned on: queued once each; the words carry the date and time, never the title; a second run sends nothing new
  update portal_settings set value = 'mirror_appointment,mirror_action' where key = 'mirror_email_kinds_enabled';
  j := mirror.send_reminders();
  ok := (j ->> 'queued')::int = 2;
  j := mirror.send_reminders();
  ok := ok and (j ->> 'queued')::int = 0 and (j ->> 'skipped')::int >= 2;
  ok := ok and exists (select 1 from public.email_outbox where to_email = 'check.ra1@example.invalid' and subject like 'Reminder: an appointment on % at 10:00 AM')
    and not exists (select 1 from public.email_outbox where to_email = 'check.ra1@example.invalid' and (html like '%Dentist%' or html like '%landlord%'));
  r := r || format('2 on: one reminder each with date and time only, no title; never twice: %s', ok);

  -- 3. the person turned appointment reminders off: a moved appointment is not emailed
  insert into mirror.profiles (auth_email, notification_prefs) values ('check.ra1@example.invalid', '{"appointment": false}')
    on conflict (auth_email) do update set notification_prefs = '{"appointment": false}';
  update mirror.appointments set starts_at = starts_at + interval '1 hour' where id = ap;
  j := mirror.send_reminders();
  ok := (j ->> 'queued')::int = 0 and exists (select 1 from mirror.notifications where individual_id = a and kind = 'mirror_appointment' and status = 'skipped'
                                                and reason like 'turned off%');
  r := r || format('3 the person''s choice wins (moved appointment, reminders off): %s', ok);

  -- 4. the job exists, daily, and calls outbox-flush only when something was queued; the function is closed to browsers
  ok := exists (select 1 from cron.job where jobname = 'mirror-reminders' and schedule = '30 13 * * *' and command like '%mirror.send_reminders()%'
                and command like '%outbox-flush%')
    and not has_function_privilege('authenticated', 'mirror.send_reminders()', 'execute');
  r := r || format('4 daily job set; closed to browsers: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
