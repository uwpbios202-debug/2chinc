-- Mirror T2.4 check: the new sign-in gate changes nothing for anyone already on file, and lets in only the right Mirror people.
-- Run AFTER the migration text in one transaction (.claude-tools/mirror-rollback-check.sh); always ends in a raise = full rollback.
do $chk$
declare
  r text[] := '{}';
  x uuid; y uuid; a uuid; b uuid; c uuid;
  n int; total int; ok boolean; j jsonb;
begin
  -- 1. switch off: for every email we know (all sign-in accounts + every people table) the new gate = the old gatekeeper
  create temp table _emails on commit drop as
    select distinct lower(e) e from (
      select email e from auth.users union all select email from tenants union all select email from condo_owners
      union all select email from condo_staff union all select email from field_staff union all select email from navigators
      union all select email from caseworkers union all select email from lease_agents union all select email from unit_occupants
      union all select email from land_contract_sellers union all select email from investors) s where e is not null and e like '%@%';
  select count(*) into total from _emails;
  select count(*) into n from _emails where public.signin_email_on_file(e) is distinct from public.condo_email_on_file(e);
  r := r || format('1 switch off: %s known emails, %s answer differently (must be 0): %s', total, n, n = 0);

  -- fictional Mirror people: A invited to 2nd Chance, B ended, C a coordinator at an inactive organization
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind, active) values ('CHECK Closed Org', 'other', false) returning id into y;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.mirror.a@example.invalid', 'CHECK A') returning id into a;
  insert into mirror.individuals (auth_email, preferred_name) values ('check.mirror.b@example.invalid', 'CHECK B') returning id into b;
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'invited'), (x, b, 'ended');
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.mirror.coord@example.invalid', 'CHECK Coordinator', 'coordinator'),
    (y, 'check.mirror.closed@example.invalid', 'CHECK Closed', 'coordinator');
  insert into mirror.organization_members (organization_id, auth_email, name, role, active) values
    (x, 'check.mirror.gone@example.invalid', 'CHECK Gone', 'coordinator', false);

  ok := not public.signin_email_on_file('check.mirror.a@example.invalid');
  r := r || format('2 switch off: invited Mirror person gets no code: %s', ok);

  -- 3. switch on: right Mirror people in, others out; old gatekeeper (View as) still says no to all of them
  update portal_settings set value = 'on' where key = 'mirror_signin_enabled';
  ok := public.signin_email_on_file('check.mirror.a@example.invalid')
    and public.signin_email_on_file('CHECK.Mirror.Coord@example.invalid ')
    and not public.signin_email_on_file('check.mirror.b@example.invalid')
    and not public.signin_email_on_file('check.mirror.closed@example.invalid')
    and not public.signin_email_on_file('check.mirror.gone@example.invalid')
    and not public.signin_email_on_file('stranger@example.invalid');
  ok := ok and not public.condo_email_on_file('check.mirror.a@example.invalid') and not public.condo_email_on_file('check.mirror.coord@example.invalid');
  r := r || format('3 switch on: invited person + active coordinator in; ended, closed org, inactive member, stranger out; View as list unchanged: %s', ok);

  -- 4. switch on: still no difference for any email that is not a Mirror email
  select count(*) into n from _emails where public.signin_email_on_file(e) is distinct from public.condo_email_on_file(e);
  r := r || format('4 switch on: existing emails answering differently (must be 0): %s', n);

  -- 5. whoami: coordinator without authenticator is told to enter it; person sees own name; stranger sees nothing of theirs
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.mirror.coord@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.mirror_whoami();
  ok := (j->>'needs_authenticator')::boolean and jsonb_array_length(j->'memberships') = 1 and j->'person' = 'null'::jsonb;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'check.mirror.a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  j := public.mirror_whoami();
  ok := ok and j->'person'->>'preferred_name' = 'CHECK A' and not (j->>'needs_authenticator')::boolean;
  -- authenticated cannot call the gate functions directly
  begin perform public.signin_email_on_file('x@example.invalid'); ok := false; exception when insufficient_privilege then null; end;
  execute 'reset role';
  r := r || format('5 whoami (coordinator needs authenticator, person sees own name) and gate not callable from a browser: %s', ok);

  -- 6. untouched: the shared login settings and functions
  select count(*) into n from portal_settings where key = 'mfa_required_roles' and value = 'staff,field,agent';
  r := r || format('6 mfa_required_roles unchanged: %s', n = 1);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
