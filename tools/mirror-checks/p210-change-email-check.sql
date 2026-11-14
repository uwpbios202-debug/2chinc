-- Mirror P2-10 check: changing a person's email (People list). Fictional people and made-up organizations; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; o2 uuid; j jsonb; ok boolean; n int;
  pu uuid; pp uuid; ps uuid; pq uuid;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); upp uuid := gen_random_uuid(); ups uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sb uuid := gen_random_uuid();
  ja text; jc text; jb text; jaa1 text;
begin
  -- A = org admin, C = coordinator (both of org O); B = admin of org O2.
  -- U = invited person, never signed in (typo email). P = active person who signed in. S = active person whose email is also office staff.
  -- Q = another person (their email is taken).
  insert into auth.users (id, email) values (ua, 'check.ea@example.invalid'), (uc, 'check.ec@example.invalid'), (ub, 'check.eb@example.invalid');
  insert into auth.users (id, email, last_sign_in_at) values (upp, 'check.ep.old@example.invalid', now() - interval '3 days'),
    (ups, 'check.es.old@example.invalid', now() - interval '3 days');
  insert into auth.sessions (id, user_id, created_at, updated_at, aal) values (sa, ua, now(), now(), 'aal2'), (sc, uc, now(), now(), 'aal2'),
    (sb, ub, now(), now(), 'aal2');
  insert into auth.sessions (id, user_id, created_at, updated_at, aal)
    select gen_random_uuid(), u, now(), now(), 'aal1' from unnest(array[upp, upp, ups]) u;
  ja := json_build_object('sub', ua, 'email', 'check.ea@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sa)::text;
  jaa1 := json_build_object('sub', ua, 'email', 'check.ea@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  jc := json_build_object('sub', uc, 'email', 'check.ec@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  jb := json_build_object('sub', ub, 'email', 'check.eb@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sb)::text;
  insert into condo_staff (email, name) values ('check.es.old@example.invalid', 'CHECK ES');
  insert into mirror.organizations (name, kind) values ('CHECK email org', 'nonprofit') returning id into o;
  insert into mirror.organizations (name, kind) values ('CHECK email other org', 'nonprofit') returning id into o2;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.ea@example.invalid', 'CHECK EA', 'org_admin'),
    (o, 'check.ec@example.invalid', 'CHECK EC', 'coordinator'), (o2, 'check.eb@example.invalid', 'CHECK EB', 'org_admin');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.eu.typo@example.invalid', 'CHECK EU', o) returning id into pu;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.ep.old@example.invalid', 'CHECK EP', o) returning id into pp;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.es.old@example.invalid', 'CHECK ES', o) returning id into ps;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.eq@example.invalid', 'CHECK EQ', o) returning id into pq;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, invited_name) values
    (o, pu, 'invited', current_date, 'CHECK EU'), (o, pp, 'active', current_date, 'CHECK EP'), (o, ps, 'active', current_date, 'CHECK ES'),
    (o, pq, 'active', current_date, 'CHECK EQ'), (o2, pp, 'invited', current_date, 'CHECK EP');
  insert into mirror.profiles (id, auth_email, display_name) values (gen_random_uuid(), 'check.ep.old@example.invalid', 'CHECK EP');
  perform set_config('role', 'authenticated', true);

  -- 1. a coordinator corrects the typo on an unused invitation: changed, invitation to the new address, no security notice, logged
  perform set_config('request.jwt.claims', jc, true);
  j := public.mirror_person_email_rule(o, pu);
  ok := j ->> 'refusal' is null and not (j ->> 'used')::boolean;
  j := public.mirror_person_email_change(o, pu, ' Check.EU@example.invalid ', 'Typo on the invitation', false);
  execute 'reset role';
  ok := ok and (select auth_email from mirror.individuals where id = pu) = 'check.eu@example.invalid'
    and j ->> 'invitation' in ('held', 'queued') and j ->> 'notice_old' is null and j ->> 'notice_new' is null
    and exists (select 1 from mirror.notifications where recipient_email = 'check.eu@example.invalid' and kind = 'mirror_invite')
    and not exists (select 1 from mirror.notifications where recipient_email = 'check.eu.typo@example.invalid' and kind = 'mirror_security')
    and exists (select 1 from mirror.audit_logs where organization_id = o and individual_id = pu and action = 'email_change'
                and actor_email = 'check.ec@example.invalid' and reason like 'Typo on the invitation%' and reason not like '%@%');
  r := r || format('1 coordinator fixes an unused email (invitation to the new address, no notice to the old, logged): %s', ok);

  -- 2. a used email: the coordinator is refused; the admin must confirm; then changed, display settings moved, old sign-ins ended, both notified
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  ok := (public.mirror_person_email_rule(o, pp) ->> 'refusal') like 'They have used this email%';
  begin perform public.mirror_person_email_change(o, pp, 'check.ep.new@example.invalid', 'Lost their email', true); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', ja, true);
  ok := ok and (public.mirror_person_email_rule(o, pp) ->> 'refusal') is null and (public.mirror_person_email_rule(o, pp) ->> 'used')::boolean;
  begin perform public.mirror_person_email_change(o, pp, 'check.ep.new@example.invalid', 'Lost their email', false); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_email_change(o, pp, 'check.ep.new@example.invalid', 'x', true); ok := false; exception when invalid_parameter_value then null; end;
  j := public.mirror_person_email_change(o, pp, 'check.ep.new@example.invalid', 'Lost their email, confirmed by video call', true);
  execute 'reset role';
  ok := ok and (select auth_email from mirror.individuals where id = pp) = 'check.ep.new@example.invalid'
    and exists (select 1 from mirror.profiles where auth_email = 'check.ep.new@example.invalid')
    and not exists (select 1 from mirror.profiles where auth_email = 'check.ep.old@example.invalid')
    and (j ->> 'signed_out_devices')::int = 2 and not exists (select 1 from auth.sessions where user_id = upp)
    and j ->> 'notice_old' in ('held', 'queued') and j ->> 'notice_new' in ('held', 'queued')
    and (select count(*) from mirror.notifications where individual_id = pp and kind = 'mirror_security'
         and recipient_email in ('check.ep.old@example.invalid', 'check.ep.new@example.invalid')) = 2
    and exists (select 1 from mirror.audit_logs where individual_id = pp and action = 'email_change' and actor_role = 'org_admin'
                and reason like '%(identity confirmed)');
  r := r || format('2 used email: coordinator refused, admin confirms; changed, settings moved, signed out, both notified: %s', ok);

  -- 3. refusals: another person's email, a coordinator's email, the caller's own, not an email, same as now, not on the list, without authenticator
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  ok := true;
  begin perform public.mirror_person_email_change(o, pq, 'check.ep.new@example.invalid', 'Their new email', true); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_email_change(o, pq, 'check.ec@example.invalid', 'Their new email', true); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_email_change(o, pq, 'check.ea@example.invalid', 'Their new email', true); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_email_change(o, pq, 'not an email', 'Their new email', true); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_email_change(o, pq, 'check.eq@example.invalid', 'Their new email', true); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_email_change(o2, pq, 'check.eq2@example.invalid', 'Their new email', true); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', jaa1, true);
  begin perform public.mirror_person_email_change(o, pq, 'check.eq2@example.invalid', 'Their new email', true); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and (select auth_email from mirror.individuals where id = pq) = 'check.eq@example.invalid';
  r := r || format('3 refused: taken, coordinator''s, own, not an email, unchanged, other org, no authenticator: %s', ok);

  -- 4. an admin of an organization the person has not accepted cannot change a used email
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jb, true);
  ok := (public.mirror_person_email_rule(o2, pp) ->> 'refusal') like 'They haven''t accepted your invitation yet%';
  begin perform public.mirror_person_email_change(o2, pp, 'check.ep.hijack@example.invalid', 'Lost their email', true); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and (select auth_email from mirror.individuals where id = pp) = 'check.ep.new@example.invalid';
  r := r || format('4 admin of an organization not yet accepted is refused: %s', ok);

  -- 5. an old email that is still a 2nd Chance portal login keeps its sign-ins
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  j := public.mirror_person_email_change(o, ps, 'check.es.new@example.invalid', 'Wants their personal email, confirmed in person', true);
  execute 'reset role';
  ok := (j ->> 'signed_out_devices')::int = 0 and exists (select 1 from auth.sessions where user_id = ups)
    and (select auth_email from mirror.individuals where id = ps) = 'check.es.new@example.invalid';
  r := r || format('5 old email still a portal login: its sign-ins are kept: %s', ok);

  -- 6. closed to anon; helpers closed to authenticated; at most 5 a day per coordinator
  ok := not has_function_privilege('anon', 'public.mirror_person_email_change(uuid, uuid, text, text, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_person_email_rule(uuid, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.email_change_refusal(uuid, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.email_used(uuid)', 'execute');
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, action, category, table_name, row_id)
    select 'check.ea@example.invalid', 'org_admin', o, 'email_change', 'general', 'individuals', 'x' from generate_series(1, 3);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  begin perform public.mirror_person_email_change(o, pq, 'check.eq2@example.invalid', 'Their new email', true); ok := false; exception when others then ok := ok and sqlerrm like 'That is 5 email changes today%'; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where organization_id = o and action = 'email_change';
  r := r || format('6 closed to anon; 5 a day per coordinator (%s logged): %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
