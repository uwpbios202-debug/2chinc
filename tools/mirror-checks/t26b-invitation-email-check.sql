-- Mirror T2.6 second half check: invitations are emailed through the T9.1 queue (held while the kind is off), resent at most once per
-- 12 hours, and only by the right people. Fictional organization and people; always rolled back (no email is sent).
do $chk$
declare
  r text[] := '{}'; o uuid; o2 uuid; a uuid; b uuid; mid uuid; s text; ok boolean; n0 int; n1 int;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); ja text; jc text;
begin
  insert into auth.users (id, email) values (ua, 'check.va@example.invalid'), (uc, 'check.vc@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sa, ua, now(), now(), now(), 'aal2'), (sc, uc, now(), now(), now(), 'aal2');
  ja := json_build_object('sub', ua, 'email', 'check.va@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sa)::text;
  jc := json_build_object('sub', uc, 'email', 'check.vc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  update portal_settings set value = '' where key = 'mirror_email_kinds_enabled';
  insert into mirror.organizations (name, kind) values ('CHECK Invite Org', 'nonprofit') returning id into o;
  insert into mirror.organizations (name, kind) values ('CHECK Other Org', 'nonprofit') returning id into o2;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.va@example.invalid', 'CHECK VA', 'org_admin');
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o2, 'check.vc@example.invalid', 'CHECK VC', 'org_admin');
  select count(*) into n0 from public.email_outbox;

  -- 1. adding a person with an email: the invitation is recorded (held, the kind is off); nothing reaches the outbox; no email = no invitation
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  a := public.mirror_person_add(jsonb_build_object('organization_id', o, 'preferred_name', 'Vee', 'email', 'check.vp@example.invalid'));
  b := public.mirror_person_add(jsonb_build_object('organization_id', o, 'preferred_name', 'No Email'));
  execute 'reset role';
  select count(*) into n1 from public.email_outbox;
  ok := n1 = n0 and exists (select 1 from mirror.notifications where individual_id = a and kind = 'mirror_invite' and status = 'held')
    and not exists (select 1 from mirror.notifications where individual_id = b);
  r := r || format('1 invitation recorded as held while off; none without an email; outbox unchanged: %s', ok);

  -- 2. turned on: "send again" queues the approved words once; a second press within 12 hours is skipped
  update portal_settings set value = 'mirror_invite,mirror_staff_invite' where key = 'mirror_email_kinds_enabled';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  s := public.mirror_invitation_resend(o, a);
  ok := s = 'queued';
  s := public.mirror_invitation_resend(o, a);
  ok := ok and s = 'skipped';
  execute 'reset role';
  ok := ok and (select subject from public.email_outbox where to_email = 'check.vp@example.invalid' order by id desc limit 1) = 'CHECK Invite Org invites you to the Human Mirror';
  r := r || format('2 on: sent again once, with the approved words; repeat within 12 hours skipped: %s', ok);

  -- 3. a new member gets the member invitation; resending it is for that organization's admins only
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  mid := public.mirror_admin_member_save(jsonb_build_object('organization_id', o, 'name', 'Mem Ber', 'email', 'check.vm@example.invalid', 'role', 'coordinator'));
  execute 'reset role';
  ok := exists (select 1 from public.email_outbox where to_email = 'check.vm@example.invalid' and subject = 'You were added to CHECK Invite Org in the Human Mirror');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  begin perform public.mirror_member_invite_resend(mid); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('3 new member invited; another organization cannot resend: %s', ok);

  -- 4. resend refused for another organization and for someone who already accepted
  begin perform public.mirror_invitation_resend(o, a); ok := false; exception when insufficient_privilege then ok := true; end;
  execute 'reset role';
  update mirror.organization_individuals set status = 'active' where organization_id = o and individual_id = a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  begin perform public.mirror_invitation_resend(o, a); ok := false; exception when invalid_parameter_value then null; end;
  r := r || format('4 resend refused for another organization and once accepted: %s', ok);

  -- 5. closed to anon; the triggers' functions closed to browsers
  execute 'reset role';
  ok := not has_function_privilege('anon', 'public.mirror_invitation_resend(uuid, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.invite_email_on_link()', 'execute');
  r := r || format('5 closed to anon and browsers: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
