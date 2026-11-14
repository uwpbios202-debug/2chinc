-- Mirror T8.8 check: outcomes and reports (D-39). Counts only, no names; safety-mode people left out (P2-06) and their number given;
-- private topics counted only where shared; corrections not counted as contacts; coordinators of the organization only; the run is in the
-- organization's audit log. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t88-reports-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; b uuid; j jsonb; ok boolean; n int; nh uuid; svc uuid; it uuid; note uuid;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uv uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sv uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; pb text; cx text; vx text; cy text; t date := (now() at time zone 'America/Chicago')::date;
begin
  insert into auth.users (id, email) values (ua, 'check.ra@example.invalid'), (ub, 'check.rb@example.invalid'), (uc, 'check.rcx@example.invalid'),
    (uv, 'check.rvx@example.invalid'), (uy, 'check.rcy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()),
    (sc, uc, now(), now(), now()), (sv, uv, now(), now(), now()), (sy, uy, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ra@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.rb@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sb)::text;
  cx := json_build_object('sub', uc, 'email', 'check.rcx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  vx := json_build_object('sub', uv, 'email', 'check.rvx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sv)::text;
  cy := json_build_object('sub', uy, 'email', 'check.rcy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  insert into mirror.organizations (name, kind) values ('CHECK RX', 'nonprofit') returning id into x;
  insert into mirror.organizations (name, kind) values ('CHECK RY', 'nonprofit') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.ra@example.invalid', 'CHECKNAME RA', x) returning id into a;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org, safety_sensitive) values ('check.rb@example.invalid', 'CHECKNAME RB', x, true) returning id into b;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.rcx@example.invalid', 'CHECK RCX', 'coordinator'), (x, 'check.rvx@example.invalid', 'CHECK RVX', 'volunteer'),
    (y, 'check.rcy@example.invalid', 'CHECK RCY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on) values (x, a, 'active', t), (x, b, 'active', t);
  perform set_config('role', 'authenticated', true);

  -- A: everyday "see and change", health "see"; needs: housing (met, confirmed), glasses (health), an ID (legal, not shared)
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform public.mirror_my_consent_set(x, 'health', 'view');
  nh := (public.mirror_need_save(null, 'housing', 'CHECKWORD bed', null, 'soon') ->> 'id')::uuid;
  perform public.mirror_need_save(null, 'physical_health', 'CHECKWORD glasses', null, 'soon');
  perform public.mirror_need_save(null, 'identity_legal', 'CHECKWORD ID', null, 'soon');
  perform public.mirror_need_status(nh, 'obtained', null);
  -- B (safety mode): everyday "see and change" and a need
  perform set_config('request.jwt.claims', pb, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform public.mirror_need_save(null, 'housing', 'CHECKWORD chair', null, 'soon');
  -- the coordinator: confirms A's need, a service for both, an appointment and a call (plus a correction) with A, gifts to A, B and outside
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_need_status(nh, 'verified', null);
  execute 'reset role';
  insert into mirror.services (organization_id, name, created_by) values (x, 'CHECK Pantry', 'check') returning id into svc;
  insert into mirror.inventory_items (organization_id, category, item, quantity, created_by) values (x, 'coats', 'CHECK coat', 10, 'check') returning id into it;
  perform set_config('role', 'authenticated', true);
  perform public.mirror_enrollment_save(jsonb_build_object('service_id', svc, 'individual_id', a));
  perform public.mirror_enrollment_save(jsonb_build_object('service_id', svc, 'individual_id', b));
  perform public.mirror_appointment_save(jsonb_build_object('individual_id', a, 'organization_id', x, 'title', 'CHECK visit', 'starts_at', now() + interval '1 hour'));
  note := (public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', x, 'kind', 'call', 'summary', 'CHECK call')) ->> 'id')::uuid;
  perform public.mirror_interaction_add(jsonb_build_object('individual_id', a, 'organization_id', x, 'corrects', note, 'summary', 'CHECK fix'));
  perform public.mirror_inventory_give(jsonb_build_object('item_id', it, 'quantity', 2, 'individual_id', a));
  perform public.mirror_inventory_give(jsonb_build_object('item_id', it, 'quantity', 1, 'individual_id', b));
  perform public.mirror_inventory_give(jsonb_build_object('item_id', it, 'quantity', 1));

  j := public.mirror_org_report(x, t - 30, t);
  -- 1. people: 1 counted, 1 in safety mode left out
  ok := (j -> 'people' ->> 'worked_with')::int = 1 and (j ->> 'safety_left_out')::int = 1 and (j -> 'people' ->> 'started')::int = 1;
  r := r || format('1 people: 1 counted, the safety-mode person left out and counted as left out: %s', ok);
  -- 2. needs: 2 noted (everyday + shared health; legal not shared; B left out), 1 met, 1 confirmed by you
  ok := (j -> 'needs' ->> 'noted')::int = 2 and (j -> 'needs' ->> 'met')::int = 1 and (j -> 'needs' ->> 'confirmed_by_you')::int = 1
    and (j -> 'needs' ->> 'open_now')::int = 1;
  r := r || format('2 needs: 2 noted (private only where shared), 1 met, 1 confirmed, 1 open: %s (%s)', ok, j -> 'needs');
  -- 3. services 1 started (B left out), appointments 1, contacts 1 (the correction is not a contact)
  ok := (j -> 'services' -> 0 ->> 'started')::int = 1 and (j -> 'appointments' ->> 'total')::int = 1 and (j -> 'contacts' ->> 'total')::int = 1
    and (j -> 'contacts' ->> 'calls')::int = 1;
  r := r || format('3 services 1 (safety-mode person left out), appointments 1, contacts 1 (correction not counted): %s (%s %s %s)', ok, j -> 'services', j -> 'appointments', j -> 'contacts');
  -- 4. goods: 2 to people (B's left out), 1 outside, by kind 3
  ok := (j -> 'goods' ->> 'to_people')::int = 2 and (j -> 'goods' ->> 'outside_the_mirror')::int = 1 and (j -> 'goods' -> 'by_kind' -> 0 ->> 'items')::int = 3;
  r := r || format('4 goods: 2 to people, 1 outside the Mirror, 3 by kind (the safety-mode gift left out): %s (%s)', ok, j -> 'goods');
  -- 5. no names or words in the report; the run is in the audit log; volunteer and another organization refused; last year is empty
  ok := position('CHECKNAME' in j::text) = 0 and position('CHECKWORD' in j::text) = 0
    and (public.mirror_org_report(x, t - 400, t - 370) -> 'needs' ->> 'noted')::int = 0;
  perform set_config('request.jwt.claims', vx, true);
  begin perform public.mirror_org_report(x, t - 30, t); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', cy, true);
  begin perform public.mirror_org_report(x, t - 30, t); ok := false; exception when others then null; end;
  execute 'reset role';
  select count(*) into n from mirror.audit_logs l where l.organization_id = x and l.action = 'report' and l.individual_id is null;
  ok := ok and n >= 2;
  r := r || format('5 no names or words; volunteer and another organization refused; last year empty; %s runs in the audit log: %s', n, ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
