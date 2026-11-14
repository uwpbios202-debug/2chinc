-- Mirror check for the privacy page promises (migration 20261119698000): hide now, adults only, change notice at sign-in.
-- Fictional people and made-up organizations; always rolled back.
do $chk$
declare
  r text[] := '{}'; o uuid; o2 uuid; x uuid; pv uuid; pk uuid; ok boolean; j jsonb; t text; y int := extract(year from (now() at time zone 'America/Chicago'))::int;
  uc uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); up uuid := gen_random_uuid(); uv uuid := gen_random_uuid(); um uuid := gen_random_uuid();
  sc uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sp uuid := gen_random_uuid(); sv uuid := gen_random_uuid(); sm uuid := gen_random_uuid();
  jc text; jb text; jp text; jv text; jm text;
begin
  insert into auth.users (id, email) values (uc, 'check.hc@example.invalid'), (ub, 'check.hb@example.invalid'), (up, 'check.hp@example.invalid'),
    (uv, 'check.hv@example.invalid'), (um, 'check.hm@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, aal) values (sc, uc, now(), now(), now(), 'aal2'), (sb, ub, now(), now(), now(), 'aal2'),
    (sp, up, now(), now(), now(), 'aal2'), (sv, uv, now(), now(), now(), 'aal1'), (sm, um, now(), now(), now(), 'aal2');
  jc := json_build_object('sub', uc, 'email', 'check.hc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  jb := json_build_object('sub', ub, 'email', 'check.hb@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sb)::text;
  jp := json_build_object('sub', up, 'email', 'check.hp@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sp)::text;
  jv := json_build_object('sub', uv, 'email', 'check.hv@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sv)::text;
  jm := json_build_object('sub', um, 'email', 'check.hm@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sm)::text;
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK hide org', 'nonprofit') returning id into o;
  insert into mirror.organizations (name, kind) values ('CHECK hide other org', 'nonprofit') returning id into o2;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.hc@example.invalid', 'CHECK HC', 'coordinator'),
    (o2, 'check.hb@example.invalid', 'CHECK HB', 'org_admin'), (x, 'check.hp@example.invalid', 'CHECK HP', 'org_admin'), (x, 'check.hm@example.invalid', 'CHECK HM', 'org_admin');
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.hp@example.invalid', 'CHECK HP', 'check'), ('check.hm@example.invalid', 'CHECK HM', 'check');
  insert into public.portal_admins (email) values ('check.hm@example.invalid');
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.hv@example.invalid', 'CHECK HV', o) returning id into pv;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.hk@example.invalid', 'CHECK HK', o) returning id into pk;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (o, pv, 'active', current_date), (o2, pv, 'active', current_date),
    (o, pk, 'active', current_date);
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, individual_id, action, category) values ('check.hb@example.invalid', 'org_admin', o2, pv, 'invitation_accept', 'general');

  -- 1. adults only: under 18 refused wherever entered; 18 this year and no birth year allowed
  ok := true;
  begin insert into mirror.individuals (preferred_name, birth_year) values ('CHECK young', y - 17); ok := false; exception when invalid_parameter_value then null; end;
  begin update mirror.individuals set birth_year = y - 10 where id = pk; ok := false; exception when invalid_parameter_value then null; end;
  insert into mirror.individuals (preferred_name, birth_year) values ('CHECK eighteen', y - 18), ('CHECK no year', null);
  r := r || format('1 under 18 refused (add and change); 18 and no birth year allowed: %s', ok);

  -- 2. a coordinator hides: confirm + reason needed; every link ended, off every list, unnamed in audit logs, no restart or re-add; no deletion asked
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  ok := true;
  begin perform public.mirror_person_hide(o, pv, 'asked on the phone, not safe', false); ok := false; exception when invalid_parameter_value then null; end;
  begin perform public.mirror_person_hide(o, pv, 'x', true); ok := false; exception when invalid_parameter_value then null; end;
  perform public.mirror_person_hide(o, pv, 'asked on the phone, not safe', true);
  ok := ok and not exists (select 1 from jsonb_array_elements(public.mirror_people(o)) e where e ->> 'id' = pv::text)
    and exists (select 1 from jsonb_array_elements(public.mirror_people(o)) e where e ->> 'id' = pk::text);
  begin perform public.mirror_person_status(o, pv, 'invited'); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_person_add(jsonb_build_object('organization_id', o, 'preferred_name', 'CHECK again', 'email', 'check.hv@example.invalid')); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', jb, true);
  ok := ok and not exists (select 1 from jsonb_array_elements(public.mirror_people(o2)) e where e ->> 'id' = pv::text)
    and not exists (select 1 from jsonb_array_elements(public.mirror_org_audit(o2, null, null) -> 'rows') e where e ->> 'person' = 'CHECK HV' or e ->> 'person_id' = pv::text);
  execute 'reset role';
  ok := ok and not (mirror.allowed(pv, 'general', 'view', o2, '_probe') ->> 'ok')::boolean      -- org B admin's claims still set
    and (select hidden_at is not null and deletion_requested_at is null from mirror.individuals where id = pv)
    and not exists (select 1 from mirror.organization_individuals where individual_id = pv and status <> 'ended')
    and exists (select 1 from mirror.audit_logs where individual_id = pv and action = 'hide' and actor_email = 'check.hc@example.invalid');
  r := r || format('2 coordinator hides (confirm + reason): links ended, off lists, unnamed in logs, no restart or re-add, no deletion: %s', ok);

  -- 3. the person still sees their Mirror and can show it again; then an organization can invite them again
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jv, true);
  ok := (public.mirror_my_settings() -> 'person' ->> 'hidden_at') is not null;
  perform public.mirror_my_unhide();
  ok := ok and (public.mirror_my_settings() -> 'person' ->> 'hidden_at') is null;
  perform public.mirror_my_hide();
  ok := ok and (public.mirror_my_settings() -> 'person' ->> 'hidden_at') is not null and (public.mirror_my_deletion(true) ->> 'hidden_at') is not null;
  ok := ok and (public.mirror_my_deletion(false) ->> 'hidden_at') is not null;            -- keeping the Mirror does not end the hiding
  perform public.mirror_my_unhide();
  perform set_config('request.jwt.claims', jb, true);
  perform public.mirror_person_status(o2, pv, 'invited');
  execute 'reset role';
  ok := ok and exists (select 1 from mirror.organization_individuals where organization_id = o2 and individual_id = pv and status = 'invited');
  r := r || format('3 person hides and shows again themselves; keeping the Mirror keeps the hiding; invite again after: %s', ok);

  -- 4. 2nd Chance hides by email, with the deletion asked on the phone; others refused
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jc, true);
  ok := true;
  begin perform public.mirror_platform_hide('check.hk@example.invalid', true, 'called, not safe', true); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', jp, true);
  t := public.mirror_platform_hide('check.nobody@example.invalid', false, 'called, not safe', true);
  ok := ok and t = 'No Mirror uses that email.';
  t := public.mirror_platform_hide('Check.HK@example.invalid', true, 'called, not safe, confirmed by video', true);
  execute 'reset role';
  ok := ok and t like 'Hidden from everyone now. Deletion asked for%'
    and (select hidden_at is not null and deletion_requested_at is not null from mirror.individuals where id = pk);
  r := r || format('4 2nd Chance hides by email (optionally with deletion asked); a coordinator cannot: %s', ok);

  -- 5. change notice: main admin only, start after today; shown at sign-in until read
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jp, true);
  ok := true;
  begin perform public.mirror_admin_change_notice_set('CHECK notice', current_date + 10); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', jm, true);
  begin perform public.mirror_admin_change_notice_set('CHECK notice', current_date); ok := false; exception when invalid_parameter_value then null; end;
  j := public.mirror_admin_change_notice_set('CHECK notice: from next month we share counts with the county.', current_date + 10);
  perform set_config('request.jwt.claims', jv, true);
  ok := ok and public.mirror_whoami() -> 'change_notice' ->> 'id' = j ->> 'id';
  perform public.mirror_notice_seen(j ->> 'id');
  ok := ok and coalesce(public.mirror_whoami() -> 'change_notice', 'null'::jsonb) = 'null'::jsonb;
  perform set_config('request.jwt.claims', jm, true);
  perform public.mirror_admin_change_notice_set('', null);
  execute 'reset role';
  ok := ok and (select value from portal_settings where key = 'mirror_change_notice') = '';
  r := r || format('5 change notice: main admin only, after today, shown until read, cleared: %s', ok);

  -- 6. closed to anon; internal helper closed to authenticated
  ok := not has_function_privilege('anon', 'public.mirror_person_hide(uuid, uuid, text, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_platform_hide(text, boolean, text, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_my_hide()', 'execute')
    and not has_function_privilege('anon', 'public.mirror_admin_change_notice_set(text, date)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.hide_individual(uuid, uuid, text, text)', 'execute');
  r := r || format('6 closed to anon; hide helper closed to authenticated: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
