-- Mirror P10-01 check: the deletion run also removes the person's Mirror emails from public.email_outbox. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; d uuid; e uuid; ok boolean; j jsonb; other_kind text;
  ob_sent bigint; ob_wait bigint; ob_old_addr bigint; ob_e bigint; ob_other bigint; ob_conf_sent bigint; ob_conf_new bigint; ob_conf_old bigint;
  n_old_addr uuid;
begin
  select kind into other_kind from public.email_outbox where kind is not null and kind not like 'mirror%' limit 1;
  insert into mirror.organizations (name, kind) values ('CHECK outbox org', 'nonprofit') returning id into o;
  -- D = due (asked 31 days ago); E = asked 29 days ago (not due)
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, deletion_requested_at)
    values ('check.od@example.invalid', 'CHECK OD', o, now() - interval '31 days') returning id into d;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, deletion_requested_at)
    values ('check.oe@example.invalid', 'CHECK OE', o, now() - interval '29 days') returning id into e;

  -- D's Mirror emails: one sent, one still waiting, one sent to an earlier address (before an email change)
  insert into public.email_outbox (to_email, subject, html, kind, sent_at) values ('check.od@example.invalid', 'CHECK invite', '<p>x</p>', 'mirror_invite', now() - interval '20 days') returning id into ob_sent;
  insert into public.email_outbox (to_email, subject, html, kind) values ('check.od@example.invalid', 'CHECK reminder', '<p>x</p>', 'mirror_appointment') returning id into ob_wait;
  insert into public.email_outbox (to_email, subject, html, kind, sent_at) values ('check.od.old@example.invalid', 'CHECK notice', '<p>x</p>', 'mirror_security', now() - interval '25 days') returning id into ob_old_addr;
  insert into mirror.notifications (recipient_email, individual_id, kind, status, outbox_id) values
    ('check.od@example.invalid', d, 'mirror_invite', 'queued', ob_sent),
    ('check.od@example.invalid', d, 'mirror_appointment', 'queued', ob_wait),
    ('check.od.old@example.invalid', d, 'mirror_security', 'queued', ob_old_addr);
  -- E's Mirror email (not due) and another site email to D's address (not a Mirror email): both stay
  insert into public.email_outbox (to_email, subject, html, kind, sent_at) values ('check.oe@example.invalid', 'CHECK invite', '<p>x</p>', 'mirror_invite', now()) returning id into ob_e;
  insert into mirror.notifications (recipient_email, individual_id, kind, status, outbox_id) values ('check.oe@example.invalid', e, 'mirror_invite', 'queued', ob_e);
  insert into public.email_outbox (to_email, subject, html, kind, sent_at) values ('check.od@example.invalid', 'CHECK other', '<p>x</p>', coalesce(other_kind, 'other'), now()) returning id into ob_other;
  -- earlier runs' confirmations: sent (goes), waiting 1 day (stays), waiting 8 days and never sent (goes)
  insert into public.email_outbox (to_email, subject, html, kind, sent_at) values ('check.c1@example.invalid', 'CHECK deleted', '<p>x</p>', 'mirror_security', now() - interval '1 day') returning id into ob_conf_sent;
  insert into public.email_outbox (to_email, subject, html, kind, created_at) values ('check.c2@example.invalid', 'CHECK deleted', '<p>x</p>', 'mirror_security', now() - interval '1 day') returning id into ob_conf_new;
  insert into public.email_outbox (to_email, subject, html, kind, created_at) values ('check.c3@example.invalid', 'CHECK deleted', '<p>x</p>', 'mirror_security', now() - interval '8 days') returning id into ob_conf_old;
  insert into mirror.notifications (recipient_email, individual_id, kind, status, outbox_id) values
    ('(deleted)', null, 'mirror_security', 'queued', ob_conf_sent), ('(deleted)', null, 'mirror_security', 'queued', ob_conf_new),
    ('(deleted)', null, 'mirror_security', 'queued', ob_conf_old);

  -- the security kind switched ON inside this rolled-back check, so today's confirmation really goes to the outbox
  insert into public.portal_settings (key, value) values ('mirror_email_kinds_enabled', 'mirror_security')
    on conflict (key) do update set value = 'mirror_security';
  j := mirror.deletion_run();

  -- 1. all of D's Mirror emails leave the outbox: sent, waiting, and the one to the earlier address
  ok := not exists (select 1 from public.email_outbox where id in (ob_sent, ob_wait, ob_old_addr))
    and not exists (select 1 from mirror.individuals where id = d);
  r := r || format('1 the deleted person''s Mirror emails are gone from the outbox (sent, waiting, earlier address) (%s): %s', j, ok);

  -- 2. kept: the person not yet due, and other site emails to the same address
  ok := exists (select 1 from public.email_outbox where id = ob_e) and exists (select 1 from public.email_outbox where id = ob_other)
    and exists (select 1 from mirror.individuals where id = e);
  r := r || format('2 not-yet-due person''s emails and non-Mirror emails to the same address are kept: %s', ok);

  -- 3. earlier confirmations: sent ones and 7-day-old unsent ones go, a recent unsent one waits for outbox-flush
  ok := not exists (select 1 from public.email_outbox where id in (ob_conf_sent, ob_conf_old)) and exists (select 1 from public.email_outbox where id = ob_conf_new)
    and not exists (select 1 from mirror.notifications where outbox_id in (ob_conf_sent, ob_conf_old))
    and exists (select 1 from mirror.notifications where outbox_id = ob_conf_new and recipient_email = '(deleted)');
  r := r || format('3 earlier confirmations removed once sent or 7 days old; a recent one waits to be sent: %s', ok);

  -- 4. today's confirmation for D is recorded without an address; if its kind is on, its outbox row is still there to be sent
  ok := exists (select 1 from mirror.notifications x where x.recipient_email = '(deleted)' and x.kind = 'mirror_security' and x.created_at >= now() - interval '1 minute'
                  and x.status = 'queued' and exists (select 1 from public.email_outbox ob where ob.id = x.outbox_id and ob.to_email = 'check.od@example.invalid' and ob.sent_at is null))
    and (j ->> 'queued')::int = 1 and (j ->> 'outbox_removed')::int = 5;
  r := r || format('4 today''s confirmation kept for sending, no address in its record; count returned: %s', ok);

  -- 5. still closed to the API roles
  ok := not has_function_privilege('authenticated', 'mirror.deletion_run()', 'execute') and not has_function_privilege('anon', 'mirror.deletion_run()', 'execute');
  r := r || format('5 closed to anon and authenticated: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
