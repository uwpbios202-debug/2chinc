-- Mirror P2-09 check: the deletion run after the 30 days. Fictional people and a made-up organization; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; d uuid; e uuid; s uuid; ok boolean; j jsonb; n int; nd uuid; fa uuid; asm uuid; nav bigint;
  ud uuid := gen_random_uuid(); us uuid := gen_random_uuid(); qid uuid; qv int; sid uuid; sv int; trial_before int;
begin
  select count(*) into trial_before from mirror.individuals;
  insert into mirror.organizations (name, kind) values ('CHECK deletion org', 'nonprofit') returning id into o;
  -- D = due (asked 31 days ago) with data everywhere; E = asked 29 days ago; S = due, but the email is also an office staff login
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, deletion_requested_at)
    values ('check.dd@example.invalid', 'CHECK DD', o, now() - interval '31 days') returning id into d;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, deletion_requested_at)
    values ('check.de@example.invalid', 'CHECK DE', o, now() - interval '29 days') returning id into e;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, deletion_requested_at)
    values ('check.ds@example.invalid', 'CHECK DS', o, now() - interval '40 days') returning id into s;
  insert into auth.users (id, email, last_sign_in_at) values (ud, 'check.dd@example.invalid', now()), (us, 'check.ds@example.invalid', now());
  insert into auth.sessions (id, user_id, created_at, updated_at) values (gen_random_uuid(), ud, now(), now()), (gen_random_uuid(), us, now(), now());
  insert into condo_staff (email, name) values ('check.ds@example.invalid', 'CHECK DS');
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (o, d, 'active', current_date), (o, e, 'active', current_date), (o, s, 'active', current_date);
  insert into mirror.consents (individual_id, organization_id, category, granted_by, access, method) values (d, o, 'health', 'check.dd@example.invalid', 'view', 'online');
  insert into mirror.needs (individual_id, dimension_key, category, title, identified_by, identified_by_role) values (d, 'housing', 'general', 'CHECK need', 'check.dd@example.invalid', 'self') returning id into nd;
  insert into mirror.need_events (need_id, by_email, by_role, to_status) values (nd, 'check.dd@example.invalid', 'self', 'identified');
  insert into mirror.interactions (individual_id, organization_id, kind, at, summary, by_email, by_role) values (d, o, 'call', now(), 'CHECK note', 'check.coord@example.invalid', 'coordinator');
  insert into mirror.daily_number_snapshots (individual_id, method_version, inputs, results, taken_by, taken_by_role) values (d, 1, '{}', '{}', 'check.dd@example.invalid', 'self');
  insert into mirror.functional_assessments (individual_id, assessed_by, assessed_by_role, is_self_report, completed_at) values (d, 'check.dd@example.invalid', 'self', true, now()) returning id into fa;
  select a.set_id, a.set_version into sid, sv from mirror.assessments a limit 1;
  select q.id into qid from mirror.reflection_questions q where q.set_id = sid limit 1;
  select max(version) into qv from mirror.question_versions where question_id = qid;
  insert into mirror.assessments (individual_id, set_id, set_version) values (d, sid, sv) returning id into asm;
  insert into mirror.assessment_responses (assessment_id, question_id, state, answered_by, answered_by_role, question_version) values (asm, qid, 'unknown', 'check.dd@example.invalid', 'self', qv);
  insert into mirror.documents (individual_id, type_key, file_name, mime, size_bytes, storage_path, uploaded_by, uploaded_by_role)
    values (d, 'state_id', 'check.pdf', 'application/pdf', 10, 'check/' || d || '/check.pdf', 'check.dd@example.invalid', 'self');
  insert into storage.objects (bucket_id, name) values ('mirror-docs', 'check/' || d || '/check.pdf');
  insert into mirror.profiles (id, auth_email, display_name) values (gen_random_uuid(), 'check.dd@example.invalid', 'CHECK DD');
  insert into mirror.rate_counts (actor_email, bucket, minute, n) values ('check.dd@example.invalid', 'edit', date_trunc('minute', now()), 1);
  insert into mirror.notifications (recipient_email, individual_id, kind, status) values ('check.dd@example.invalid', d, 'mirror_invite', 'held');
  insert into nav_referrals (first_name, mirror_individual_id) values ('CHECK DD', d) returning ref_no into nav;
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, individual_id, action, category, reason) values
    ('check.dd@example.invalid', 'self', null, d, 'delete_request', 'general', null),
    ('check.coord@example.invalid', 'coordinator', o, d, 'email_change', 'general', 'confirmed by phone with her sister');

  -- 1. the run deletes only who is due; the 29-day request and everyone else stay
  j := mirror.deletion_run();
  ok := (j ->> 'deleted')::int = 2 and not exists (select 1 from mirror.individuals where id in (d, s))
    and exists (select 1 from mirror.individuals where id = e) and (select count(*) from mirror.individuals) = trial_before + 1;
  r := r || format('1 deletes only people 30 days after their request (%s): %s', j, ok);

  -- 2. everything of the person is gone; the stored file is queued for the hourly sweep
  ok := not exists (select 1 from mirror.needs where id = nd) and not exists (select 1 from mirror.need_events where need_id = nd)
    and not exists (select 1 from mirror.interactions where individual_id = d) and not exists (select 1 from mirror.daily_number_snapshots where individual_id = d)
    and not exists (select 1 from mirror.functional_assessments where id = fa) and not exists (select 1 from mirror.assessment_responses where assessment_id = asm)
    and not exists (select 1 from mirror.documents where individual_id = d)
    and exists (select 1 from mirror.document_removals where path = 'check/' || d || '/check.pdf') and not exists (select 1 from mirror.consents where individual_id = d)
    and not exists (select 1 from mirror.organization_individuals where individual_id = d)
    and not exists (select 1 from mirror.profiles where auth_email = 'check.dd@example.invalid')
    and not exists (select 1 from mirror.rate_counts where actor_email = 'check.dd@example.invalid')
    and not exists (select 1 from mirror.notifications where recipient_email = 'check.dd@example.invalid');
  r := r || format('2 the whole Mirror is gone (answers, needs and history, notes, Daily Numbers, finished check-ins, documents, file queued for removal, sharing, settings): %s', ok);

  -- 3. the audit log keeps only that it happened: ids and actions, no email of the person, no reasons; one 'deleted' row
  ok := (select count(*) from mirror.audit_logs where individual_id = d) = 3
    and not exists (select 1 from mirror.audit_logs where individual_id = d and (actor_email = 'check.dd@example.invalid' or reason is not null))
    and exists (select 1 from mirror.audit_logs where individual_id = d and action = 'deleted' and actor_role = 'system')
    and exists (select 1 from mirror.audit_logs where individual_id = d and action = 'email_change' and actor_email = 'check.coord@example.invalid');
  r := r || format('3 audit log keeps ids only (person''s email and reasons cleared, deleted row added): %s', ok);

  -- 4. confirmation email held (kind off) without an address kept; sign-in account removed, but kept for an office staff login
  ok := exists (select 1 from mirror.notifications where recipient_email = '(deleted)' and kind = 'mirror_security' and status in ('held', 'queued'))
    and not exists (select 1 from auth.users where id = ud) and not exists (select 1 from auth.sessions where user_id = ud)
    and exists (select 1 from auth.users where id = us);
  r := r || format('4 confirmation email (no address kept); account removed unless it is also a portal login: %s', ok);

  -- 5. kept: the Navigator's own record, its link cleared; the audit log is still append-only outside the run
  ok := exists (select 1 from nav_referrals where ref_no = nav and mirror_individual_id is null);
  insert into mirror.audit_logs (actor_email, actor_role, individual_id, action, category, reason) values ('check.de@example.invalid', 'self', e, 'delete_request', 'general', 'x');
  begin update mirror.audit_logs set reason = null where individual_id = e; ok := false; exception when insufficient_privilege then null; end;
  perform set_config('mirror.redact_individual', e::text, true);
  begin update mirror.audit_logs set action = 'other', reason = null where individual_id = e; ok := false; exception when insufficient_privilege then null; end;
  begin delete from mirror.audit_logs where individual_id = e; ok := false; exception when insufficient_privilege then null; end;
  perform set_config('mirror.redact_individual', '', true);
  r := r || format('5 Navigator record kept (link cleared); audit log still append-only (redaction only inside the run): %s', ok);

  -- 6. closed to the API roles; the daily job is scheduled
  ok := not has_function_privilege('authenticated', 'mirror.deletion_run()', 'execute') and not has_function_privilege('anon', 'mirror.deletion_run()', 'execute')
    and not has_function_privilege('authenticated', 'mirror.deletion_due()', 'execute')
    and exists (select 1 from cron.job where jobname = 'mirror-deletions' and schedule = '15 14 * * *' and active);
  r := r || format('6 closed to anon and authenticated; daily job mirror-deletions scheduled: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
