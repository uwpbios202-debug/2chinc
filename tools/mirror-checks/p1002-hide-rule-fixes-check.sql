-- Mirror check for P10-02, P10-03, P10-04 (migration 20261119699000). Fictional people and made-up organizations; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; o2 uuid; pi uuid; pa uuid; pe uuid; ok boolean; j jsonb;
  uc uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); ui uuid := gen_random_uuid(); ue uuid := gen_random_uuid(); uo uuid := gen_random_uuid();
  sc uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); si uuid := gen_random_uuid(); so uuid := gen_random_uuid();
  jc text; jb text; ji text; jgone text; jnosid text;
begin
  insert into auth.users (id, email, last_sign_in_at) values (uc, 'check.fc@example.invalid', now()), (ub, 'check.fb@example.invalid', now()),
    (ui, 'check.fi@example.invalid', now()), (ue, 'check.fe@example.invalid', now()), (uo, 'check.fo@example.invalid', now());
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sc, uc, now(), now(), now(), 'aal2'),
    (sb, ub, now(), now(), now(), 'aal2'), (si, ui, now(), now(), now(), 'aal1'), (so, uo, now(), now(), now(), 'aal1');
  jc := json_build_object('sub', uc, 'email', 'check.fc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  jb := json_build_object('sub', ub, 'email', 'check.fb@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sb)::text;
  ji := json_build_object('sub', ui, 'email', 'check.fi@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', si)::text;
  jgone := json_build_object('sub', uo, 'email', 'check.fo@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  jnosid := json_build_object('sub', uo, 'email', 'check.fo@example.invalid', 'aal', 'aal1', 'role', 'authenticated')::text;
  insert into mirror.organizations (name, kind) values ('CHECK fix org', 'nonprofit') returning id into o;
  insert into mirror.organizations (name, kind) values ('CHECK fix other org', 'nonprofit') returning id into o2;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.fc@example.invalid', 'CHECK FC', 'coordinator'),
    (o2, 'check.fb@example.invalid', 'CHECK FB', 'org_admin');
  -- PI: only invited by O, active with O2.  PA: active with O.  PE: signed in, their link with O2 ended.
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.fi@example.invalid', 'CHECK FI', o2) returning id into pi;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.fa@example.invalid', 'CHECK FA', o) returning id into pa;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.fe@example.invalid', 'CHECK FE', o2) returning id into pe;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, ended_on) values
    (o, pi, 'invited', current_date, null), (o2, pi, 'active', current_date, null), (o, pa, 'active', current_date, null),
    (o2, pe, 'ended', current_date - 30, current_date - 1);

  -- 1. P10-02: an organization that only invited them cannot hide them; their link elsewhere stays active
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  ok := true;
  begin perform public.mirror_person_hide(o, pi, 'asked on the phone, not safe', true); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and (select hidden_at from mirror.individuals where id = pi) is null
    and exists (select 1 from mirror.organization_individuals where organization_id = o2 and individual_id = pi and status = 'active');
  r := r || format('1 an invitation not accepted is not enough to hide; their other organization keeps them: %s', ok);

  -- 2. an organization they work with still can, and every link ends (unchanged)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  perform public.mirror_person_hide(o, pa, 'asked on the phone, not safe', true);
  execute 'reset role';
  ok := (select hidden_at from mirror.individuals where id = pa) is not null
    and not exists (select 1 from mirror.organization_individuals where individual_id = pa and status <> 'ended');
  r := r || format('2 an organization they actively work with can hide them; every link ended: %s', ok);

  -- 3. P10-03: the email rule answers an ended link or a hidden person with a refusal only, no "used"; an active link as before
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jb, true);
  j := public.mirror_person_email_rule(o2, pe);
  ok := j ->> 'refusal' is not null and j -> 'used' = 'null'::jsonb;
  perform set_config('request.jwt.claims', jc, true);
  j := public.mirror_person_email_rule(o, pa);
  ok := ok and j ->> 'refusal' is not null and j -> 'used' = 'null'::jsonb;
  perform set_config('request.jwt.claims', jb, true);
  j := public.mirror_person_email_rule(o2, pi);
  ok := ok and j ->> 'refusal' is null and (j ->> 'used')::boolean;
  execute 'reset role';
  r := r || format('3 email rule: ended link and hidden person get a refusal only; an active link still gets the full answer: %s', ok);

  -- 4. P10-04: notice_seen refuses an ended Mirror session and a view-as sign-in; a current one still works
  perform set_config('role', 'authenticated', true);
  ok := true;
  perform set_config('request.jwt.claims', jgone, true);
  begin perform public.mirror_notice_seen('CHECK1'); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', jnosid, true);
  begin perform public.mirror_notice_seen('CHECK1'); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', ji, true);
  perform public.mirror_notice_seen('CHECK1');
  execute 'reset role';
  ok := ok and not exists (select 1 from mirror.profiles where auth_email = 'check.fo@example.invalid')
    and exists (select 1 from mirror.profiles where auth_email = 'check.fi@example.invalid' and notice_seen = 'CHECK1');
  r := r || format('4 notice_seen refuses an ended session and view-as; a current sign-in still records it: %s', ok);

  -- 5. closed to anon
  ok := not has_function_privilege('anon', 'public.mirror_person_hide(uuid, uuid, text, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_person_email_rule(uuid, uuid)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_notice_seen(text)', 'execute')
    and has_function_privilege('authenticated', 'public.mirror_notice_seen(text)', 'execute');
  r := r || format('5 closed to anon, open to signed-in users: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
