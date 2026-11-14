-- Phase 2 fix 3 check (migration 20261119267000): linking an existing Mirror by email needs the person's yes, and shows the
-- organization nothing of theirs before it. Always rolled back: sh ./.claude-tools/mirror-rollback-check.sh <migration> <this file>
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; z uuid; a uuid; a2 uuid; c uuid; j jsonb; p jsonb; ok boolean; n int;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.lx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cy text := json_build_object('sub', gen_random_uuid(), 'email', 'check.ly@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cz text := json_build_object('sub', gen_random_uuid(), 'email', 'check.lz@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.la@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK Org Y', 'other') returning id into y;
  insert into mirror.organizations (name, kind) values ('CHECK Org Z', 'other') returning id into z;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.lx@example.invalid', 'CHECK X', 'coordinator'), (y, 'check.ly@example.invalid', 'CHECK Y', 'coordinator'),
    (z, 'check.lz@example.invalid', 'CHECK Z', 'coordinator');
  perform set_config('role', 'authenticated', true);

  -- org X creates A (email) with full details; A accepts X
  perform set_config('request.jwt.claims', cx, true);
  a := public.mirror_person_add(jsonb_build_object('organization_id', x, 'preferred_name', 'Real Name A', 'legal_name', 'Legal A', 'birth_year', 1980, 'email', 'check.la@example.invalid'));
  c := public.mirror_person_add(jsonb_build_object('organization_id', x, 'preferred_name', 'CHECK No Email'));
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_invitation_answer(x, true);

  -- 1 org Y adds the same email under another name: Y sees only its typed name and the email, nothing of A's own Mirror
  perform set_config('request.jwt.claims', cy, true);
  a2 := public.mirror_person_add(jsonb_build_object('organization_id', y, 'preferred_name', 'Typed By Y', 'legal_name', 'Y Legal Guess', 'birth_year', 1990, 'email', 'check.la@example.invalid'));
  select q into p from jsonb_array_elements(public.mirror_people(y)) q where q ->> 'id' = a::text;
  ok := a2 = a and p ->> 'status' = 'invited' and p ->> 'preferred_name' = 'Typed By Y' and p ->> 'legal_name' is null and p ->> 'birth_year' is null
    and p ->> 'safety_sensitive' is null and p ->> 'email' = 'check.la@example.invalid';
  r := r || format('1 Y invited an existing Mirror: sees only "Typed By Y" + email, no legal name, birth year or safety flag: %s', ok);

  -- 2 Y cannot make the link active itself
  begin perform public.mirror_person_status(y, a, 'active'); ok := false; exception when insufficient_privilege then ok := true; end;
  execute 'reset role';
  ok := ok and (select status from mirror.organization_individuals where organization_id = y and individual_id = a) = 'invited';
  perform set_config('role', 'authenticated', true);
  r := r || format('2 Y setting the invited person to active is refused; still invited: %s', ok);

  -- 3 the person accepts Y: now Y sees their real details
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_invitation_answer(y, true);
  perform set_config('request.jwt.claims', cy, true);
  select q into p from jsonb_array_elements(public.mirror_people(y)) q where q ->> 'id' = a::text;
  ok := p ->> 'status' = 'active' and p ->> 'preferred_name' = 'Real Name A' and p ->> 'legal_name' = 'Legal A' and (p ->> 'birth_year')::int = 1980;
  r := r || format('3 after the person says yes, Y sees their real name, legal name and birth year: %s', ok);

  -- 4 org Z invites, the person declines: Z still sees only its typed name; Z cannot force it active, may re-invite
  perform set_config('request.jwt.claims', cz, true);
  perform public.mirror_person_add(jsonb_build_object('organization_id', z, 'preferred_name', 'Typed By Z', 'email', 'check.la@example.invalid'));
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_invitation_answer(z, false);
  perform set_config('request.jwt.claims', cz, true);
  select q into p from jsonb_array_elements(public.mirror_people(z)) q where q ->> 'id' = a::text;
  ok := p ->> 'status' = 'ended' and p ->> 'preferred_name' = 'Typed By Z' and p ->> 'legal_name' is null;
  begin perform public.mirror_person_status(z, a, 'active'); ok := false; exception when insufficient_privilege then null; end;
  perform public.mirror_person_status(z, a, 'invited');
  execute 'reset role';
  ok := ok and (select status from mirror.organization_individuals where organization_id = z and individual_id = a) = 'invited';
  perform set_config('role', 'authenticated', true);
  r := r || format('4 declined: Z sees only "Typed By Z"; forcing active refused; re-invite allowed: %s', ok);

  -- 5 the creating organization still sees everything; a person with no email: restart to active works, "invited" refused
  perform set_config('request.jwt.claims', cx, true);
  select q into p from jsonb_array_elements(public.mirror_people(x)) q where q ->> 'id' = a::text;
  ok := p ->> 'preferred_name' = 'Real Name A' and p ->> 'legal_name' = 'Legal A';
  perform public.mirror_person_status(x, c, 'ended');
  perform public.mirror_person_status(x, c, 'active');
  begin perform public.mirror_person_status(x, c, 'invited'); ok := false; exception when invalid_parameter_value then null; end;
  execute 'reset role';
  ok := ok and (select status from mirror.organization_individuals where organization_id = x and individual_id = c) = 'active';
  perform set_config('role', 'authenticated', true);
  r := r || format('5 creating org sees full details; no-email person: end + restart works, "invited" refused: %s', ok);

  -- 6 nothing of the person was overwritten by Y's or Z's typing
  execute 'reset role';
  select count(*) into n from mirror.individuals where id = a and preferred_name = 'Real Name A' and legal_name = 'Legal A' and birth_year = 1980;
  r := r || format('6 the person''s own details unchanged by other organizations: %s', n = 1);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
