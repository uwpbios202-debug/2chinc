-- Mirror P2-15 check: rate limits (D-43). Normal use is counted and allowed; quiet probes are not counted; at the limit a member's look,
-- the person's own change, adding people and reports are refused with the plain message; a member's refusal is logged at most once per
-- 10 minutes. Fictional people; always rolled back. (A recent rate_limit audit row is placed in this transaction first, so no refusal is
-- written through the second connection and nothing outlives the rollback.)
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/p215-rate-limits-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; a uuid; ok boolean; n0 bigint; n1 bigint; msg text; l record;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
  pa text; cx text; m timestamptz := date_trunc('minute', now());
begin
  insert into auth.users (id, email) values (ua, 'check.rl.a@example.invalid'), (uc, 'check.rl.cx@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.rl.a@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.rl.cx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  insert into mirror.organizations (name, kind) values ('CHECK RL X', 'nonprofit') returning id into x;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.rl.a@example.invalid', 'CHECK RL A', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (x, 'check.rl.cx@example.invalid', 'CHECK RL CX', 'org_admin');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, action, category, table_name, reason)
  values ('check.rl.cx@example.invalid', 'org_admin', x, 'refused', 'general', 'needs', 'rate_limit');

  -- 1. the limits, in one place
  l := mirror.rate_limit('edit'); ok := l.max_n = 600 and l.minutes = 10;
  l := mirror.rate_limit('look'); ok := ok and l.max_n = 3000 and l.minutes = 60;
  l := mirror.rate_limit('person_add'); ok := ok and l.max_n = 100;
  l := mirror.rate_limit('referral_send'); ok := ok and l.max_n = 30;
  r := r || format('1 limits: changes 600 per 10 minutes, looks 3,000 an hour, adding people 100, referrals 30: %s', ok);

  -- 2. normal use: a look is counted; a quiet probe is not
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  select coalesce(sum(n), 0) into n0 from mirror.rate_counts where actor_email = 'check.rl.cx@example.invalid' and bucket = 'look';
  perform mirror.may(a, 'general', 'view'); perform mirror.may(a, 'general', 'view');
  select coalesce(sum(n), 0) into n1 from mirror.rate_counts where actor_email = 'check.rl.cx@example.invalid' and bucket = 'look';
  ok := n1 = n0;
  perform public.mirror_answers_history('reflection_vision', 'person', a);
  select coalesce(sum(n), 0) into n1 from mirror.rate_counts where actor_email = 'check.rl.cx@example.invalid' and bucket = 'look';
  ok := ok and n1 > n0;
  r := r || format('2 a look is counted (%s), quiet probes are not: %s', n1 - n0, ok);

  -- 3. at the limit, the member's next look is refused with the plain message; no second refusal row within 10 minutes
  insert into mirror.rate_counts (actor_email, bucket, minute, n) values ('check.rl.cx@example.invalid', 'look', m - interval '5 minutes', 3000);
  ok := false;
  begin perform public.mirror_answers_history('reflection_vision', 'person', a); exception when others then msg := sqlerrm; ok := sqlerrm like 'Too many in a short time%'; end;
  ok := ok and (select count(*) from mirror.audit_logs where actor_email = 'check.rl.cx@example.invalid' and reason = 'rate_limit') = 1;
  r := r || format('3 member over the hourly looks: refused ("%s"), refusal logged once only: %s', left(coalesce(msg, ''), 40), ok);

  -- 4. the person at 600 changes in 10 minutes: their next change is refused; their own reading still works
  insert into mirror.rate_counts (actor_email, bucket, minute, n) values ('check.rl.a@example.invalid', 'edit', m - interval '3 minutes', 600);
  perform set_config('request.jwt.claims', pa, true);
  ok := false;
  begin perform public.mirror_need_save(null, 'housing', 'CHECK bed', null, 'soon'); exception when others then ok := sqlerrm like 'Too many in a short time%'; end;
  ok := ok and jsonb_typeof(public.mirror_needs_list() -> 'needs') = 'array';
  r := r || format('4 the person over 600 changes in 10 minutes: refused; their own reading still works: %s', ok);

  -- 5. adding people over 100 an hour and reports over 60 an hour are refused (errcode 54000); older counts no longer count
  insert into mirror.rate_counts (actor_email, bucket, minute, n) values
    ('check.rl.cx@example.invalid', 'person_add', m - interval '10 minutes', 100), ('check.rl.cx@example.invalid', 'report', m - interval '2 hours', 500);
  perform set_config('request.jwt.claims', cx, true);
  ok := false;
  begin perform public.mirror_person_add(jsonb_build_object('organization_id', x, 'preferred_name', 'CHECK RL B')); exception when sqlstate '54000' then ok := true; end;
  ok := ok and public.mirror_org_report(x, current_date - 30, current_date) ? 'people';
  r := r || format('5 adding people over the hour refused (54000); report counts from 2 hours ago no longer count: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
