-- Phase 2 fix 1 check: invited -> accept -> active (coordinator can now see general answers); decline -> ended; nobody else can answer
-- someone's invitation; logged. Fictional people; always rolled back.
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; j jsonb; n int; ok boolean;
  pa text := json_build_object('sub', gen_random_uuid(), 'email', 'check.inv@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  pb text := json_build_object('sub', gen_random_uuid(), 'email', 'check.other@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
  cx text := json_build_object('sub', gen_random_uuid(), 'email', 'check.invc@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', gen_random_uuid())::text;
begin
  select id into x from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK Second Org', 'navigator') returning id into y;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.invc@example.invalid', 'CHECK Coordinator', 'coordinator');
  insert into mirror.individuals (auth_email, preferred_name) values ('check.other@example.invalid', 'CHECK Other');
  perform set_config('role', 'authenticated', true);

  -- the coordinator adds a person with an email: invited, and nothing of theirs is visible yet
  perform set_config('request.jwt.claims', cx, true);
  a := public.mirror_person_add(jsonb_build_object('organization_id', x, 'preferred_name', 'CHECK Invited', 'email', 'check.inv@example.invalid'));
  execute 'reset role';
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (y, a, 'invited');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_answer_save('reflection_identity', 'proud', '"My kids"');
  j := public.mirror_whoami();
  ok := (j ->> 'invitations')::int = 2 and jsonb_array_length(public.mirror_my_invitations()) = 2
    and (select x2 ->> 'coordinator' from jsonb_array_elements(public.mirror_my_invitations()) x2 where x2 ->> 'organization_id' = x::text) = 'CHECK Coordinator';
  perform set_config('request.jwt.claims', cx, true);
  begin perform public.mirror_set_get('reflection_identity', a); ok := ok and false; exception when insufficient_privilege then null; end;
  r := r || format('1 invited: the person sees 2 waiting invitations (with the coordinator''s name); the coordinator sees nothing yet: %s', ok);

  -- someone else cannot answer the person's invitation
  perform set_config('request.jwt.claims', pb, true);
  begin perform public.mirror_my_invitation_answer(x, true); ok := false; exception when no_data_found then ok := true; end;
  r := r || format('2 another person cannot accept it for them: %s', ok);

  -- the person accepts one and declines the other
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_invitation_answer(x, true);
  perform public.mirror_my_invitation_answer(y, false);
  ok := jsonb_array_length(public.mirror_my_invitations()) = 0 and (public.mirror_whoami() ->> 'invitations')::int = 0;
  begin perform public.mirror_my_invitation_answer(x, true); ok := ok and false; exception when no_data_found then null; end;
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_set_get('reflection_identity', a);
  ok := ok and (select q -> 'answer' ->> 'value' from jsonb_array_elements(j -> 'questions') q where q ->> 'key' = 'proud') = 'My kids';
  ok := ok and (select p2 ->> 'status' from jsonb_array_elements(public.mirror_people(x)) p2 where p2 ->> 'id' = a::text) = 'active';
  execute 'reset role';
  select count(*) into n from mirror.organization_individuals where individual_id = a and organization_id = y and status = 'ended';
  r := r || format('3 accept -> active, the coordinator now sees the answer; decline -> ended; answering twice refused: %s', ok and n = 1);

  select count(*) into n from mirror.audit_logs where individual_id = a and actor_role = 'self' and action in ('invitation_accept', 'invitation_decline');
  r := r || format('4 both answers logged (2): %s', n);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
