-- Mirror P2-11 check: authenticator reset by an organization's admin or a 2nd Chance platform admin. Fictional people and a made-up
-- organization; always rolled back (their authenticators and sign-ins exist only inside this transaction).
do $chk$
declare
  r text[] := '{}'; x uuid; o uuid; o2 uuid; j jsonb; ok boolean; n int;
  mc uuid; ms uuid; mo uuid; mself uuid; mp uuid; mpa uuid;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); us uuid := gen_random_uuid(); uo uuid := gen_random_uuid();
  up uuid := gen_random_uuid(); uk uuid := gen_random_uuid(); um uuid := gen_random_uuid();
  ja text; jaa1 text; jk text; jp text; sa uuid := gen_random_uuid(); sk uuid := gen_random_uuid(); sp uuid := gen_random_uuid();
begin
  -- A = outside org admin; C = plain coordinator; S = coordinator who is also 2nd Chance office staff; O = coordinator also in another org;
  -- K = plain coordinator of the same org (not an admin); P = 2nd Chance platform admin; M = a portal admin who is a member of the org
  insert into auth.users (id, email) values (ua, 'check.ia@example.invalid'), (uc, 'check.ic@example.invalid'), (us, 'check.is@example.invalid'),
    (uo, 'check.io@example.invalid'), (up, 'check.ip@example.invalid'), (uk, 'check.ik@example.invalid'), (um, 'check.im@example.invalid');
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
    select gen_random_uuid(), u, 'check app', 'totp', 'verified', now(), now() from unnest(array[ua, uc, us, uo, up, uk, um]) u;
  insert into auth.sessions (id, user_id, created_at, updated_at, aal)
    select gen_random_uuid(), u, now(), now(), 'aal2' from unnest(array[uc, uc, us, um]) u;
  insert into auth.sessions (id, user_id, created_at, updated_at, aal) values (sa, ua, now(), now(), 'aal2'), (sk, uk, now(), now(), 'aal2'), (sp, up, now(), now(), 'aal2');
  ja := json_build_object('sub', ua, 'email', 'check.ia@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sa)::text;
  jaa1 := json_build_object('sub', ua, 'email', 'check.ia@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  jk := json_build_object('sub', uk, 'email', 'check.ik@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sk)::text;
  jp := json_build_object('sub', up, 'email', 'check.ip@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sp)::text;
  insert into condo_staff (email, name) values ('check.is@example.invalid', 'CHECK IS');
  insert into public.portal_admins (email) values ('check.im@example.invalid');
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK outside org', 'nonprofit') returning id into o;
  insert into mirror.organizations (name, kind) values ('CHECK other org', 'nonprofit') returning id into o2;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.ia@example.invalid', 'CHECK IA', 'org_admin') returning id into mself;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.ic@example.invalid', 'CHECK IC', 'coordinator') returning id into mc;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.is@example.invalid', 'CHECK IS', 'coordinator') returning id into ms;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.io@example.invalid', 'CHECK IO', 'coordinator') returning id into mo;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o2, 'check.io@example.invalid', 'CHECK IO', 'coordinator');
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.ik@example.invalid', 'CHECK IK', 'coordinator');
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (o, 'check.im@example.invalid', 'CHECK IM', 'coordinator') returning id into mpa;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.ip@example.invalid', 'CHECK IP', 'org_admin') returning id into mp;
  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.ip@example.invalid', 'CHECK IP', 'check');
  perform set_config('role', 'authenticated', true);

  -- 1. the org admin sees who has an authenticator and who they may reset
  perform set_config('request.jwt.claims', ja, true);
  j := public.mirror_admin_authenticators(o);
  ok := (select (e ->> 'has_authenticator')::boolean and e ->> 'refusal' is null from jsonb_array_elements(j) e where e ->> 'id' = mc::text)
    and (select e ->> 'refusal' like 'Only 2nd Chance%' from jsonb_array_elements(j) e where e ->> 'id' = ms::text)
    and (select e ->> 'refusal' like 'Only 2nd Chance%' from jsonb_array_elements(j) e where e ->> 'id' = mo::text)
    and (select e ->> 'refusal' like 'You cannot reset your own%' from jsonb_array_elements(j) e where e ->> 'id' = mself::text);
  r := r || format('1 admin page shows authenticators and who may be reset: %s', ok);

  -- 2. the org admin resets the plain coordinator: authenticator gone, signed out everywhere, in the org's audit log with the reason
  begin perform public.mirror_admin_authenticator_reset(o, mc, 'Lost their phone', false); ok := false; exception when invalid_parameter_value then ok := true; end;
  begin perform public.mirror_admin_authenticator_reset(o, mc, 'x', true); ok := false; exception when invalid_parameter_value then null; end;
  j := public.mirror_admin_authenticator_reset(o, mc, 'Lost their phone, confirmed by phone call', true);
  execute 'reset role';
  ok := ok and (j ->> 'authenticators_removed')::int = 1 and (j ->> 'signed_out_devices')::int = 2
    and not exists (select 1 from auth.mfa_factors where user_id = uc) and not exists (select 1 from auth.sessions where user_id = uc)
    and exists (select 1 from mirror.audit_logs where organization_id = o and action = 'authenticator_reset' and row_id = mc::text
                and actor_email = 'check.ia@example.invalid' and reason like 'Lost their phone%');
  r := r || format('2 org admin resets a coordinator (confirm + reason needed; removed, signed out, logged): %s', ok);

  -- 3. the org admin is refused for themself, a 2nd Chance staff sign-in, someone in another org; refused without the authenticator
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  ok := true;
  begin perform public.mirror_admin_authenticator_reset(o, mself, 'Lost my phone', true); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_admin_authenticator_reset(o, ms, 'Lost their phone', true); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_admin_authenticator_reset(o, mo, 'Lost their phone', true); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', jaa1, true);
  begin perform public.mirror_admin_authenticator_reset(o, mo, 'Lost their phone', true); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and exists (select 1 from auth.mfa_factors where user_id = us) and exists (select 1 from auth.mfa_factors where user_id = uo)
    and exists (select 1 from auth.mfa_factors where user_id = ua);
  r := r || format('3 org admin refused: self, 2nd Chance staff, member of another org, without authenticator: %s', ok);

  -- 4. a coordinator (not an admin) cannot see or reset; a member of another org cannot reach this org
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jk, true);
  ok := true;
  begin perform public.mirror_admin_authenticators(o); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.mirror_admin_authenticator_reset(o, mo, 'Lost their phone', true); ok := false; exception when insufficient_privilege then null; end;
  r := r || format('4 a coordinator cannot list or reset: %s', ok);

  -- 5. the platform admin may reset the staff member and the two-org member, never a portal admin
  perform set_config('request.jwt.claims', jp, true);
  j := public.mirror_admin_authenticator_reset(o, ms, 'New phone, confirmed in person', true);
  ok := (j ->> 'authenticators_removed')::int = 1;
  j := public.mirror_admin_authenticator_reset(o, mo, 'New phone, confirmed in person', true);
  ok := ok and (j ->> 'authenticators_removed')::int = 1;
  begin perform public.mirror_admin_authenticator_reset(o, mpa, 'New phone', true); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  ok := ok and exists (select 1 from auth.mfa_factors where user_id = um) and exists (select 1 from auth.sessions where user_id = um)
    and exists (select 1 from mirror.audit_logs where organization_id = o and action = 'authenticator_reset' and row_id = ms::text and actor_role = 'platform_admin');
  r := r || format('5 platform admin resets staff and two-org members, never a portal admin: %s', ok);

  -- 6. closed to anon; at most 5 a day per admin
  ok := not has_function_privilege('anon', 'public.mirror_admin_authenticator_reset(uuid, uuid, text, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.mirror_admin_authenticators(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'mirror.authenticator_reset_refusal(uuid, text)', 'execute');
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, action, category, table_name, row_id)
    select 'check.ia@example.invalid', 'org_admin', o, 'authenticator_reset', 'organization', 'organization_members', 'x' from generate_series(1, 4);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', ja, true);
  begin perform public.mirror_admin_authenticator_reset(o, mc, 'Lost their phone again', true); ok := false; exception when others then ok := ok and sqlerrm like 'That is 5 resets today%'; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs where organization_id = o and action = 'authenticator_reset';
  r := r || format('6 closed to anon; 5 a day per admin (%s logged): %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
