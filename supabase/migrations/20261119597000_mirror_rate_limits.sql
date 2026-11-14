-- The Human Mirror P2-15 (Phase 10 step 30; Stephen 11/13/2026 "go"): rate limits.
-- Before: nothing limited how often a signed-in user could call the Mirror. A stolen session or a runaway script could read every
-- record an organization may see, or flood the database and the office's email, as fast as the network allows.
-- Now (D-43), per sign-in, counted per minute in mirror.rate_counts:
--   * every change through the gate (mirror.allowed, action edit): 600 per 10 minutes (about one a second; hands-free answering stays
--     far below it);
--   * every look at a person's record by an organization member (mirror.allowed, action view, not a quiet probe): 3,000 per hour;
--   * adding people (mirror_person_add): 100 per hour; sending referrals (mirror_referral_send, which emails the office): 30 per hour;
--   * organization reports (mirror_org_report): 60 per hour; platform pages (mirror_platform_overview / _audit): 300 per hour.
-- Over a limit: "Too many in a short time. Please wait a few minutes and try again." (errcode 54000), and for a member's look or change
-- one refusal per 10 minutes is written to the audit log (reason rate_limit). The person's own reads are not limited.
-- The limits are in one function, mirror.rate_limit(bucket). The sign-in code itself is limited by Supabase Auth and Turnstile.
-- The function bodies below are the live ones (11/13/2026) with only the rate checks added. New table: service_role only, row security on.

create table mirror.rate_counts (
  actor_email text not null,
  bucket text not null,
  minute timestamptz not null,
  n int not null default 1,
  primary key (actor_email, bucket, minute)
);
alter table mirror.rate_counts enable row level security;
revoke all on mirror.rate_counts from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.rate_counts to service_role;

-- the limits, in one place: how many per how many minutes
create or replace function mirror.rate_limit(p_bucket text, out max_n int, out minutes int)
language sql immutable as $$
  select case p_bucket when 'edit' then 600 when 'look' then 3000 when 'person_add' then 100 when 'referral_send' then 30
                       when 'report' then 60 when 'platform' then 300 else 600 end,
         case p_bucket when 'edit' then 10 else 60 end;
$$;

-- count this call; true while within the limit (no sign-in: true, the gate refuses it anyway)
create or replace function mirror.rate_ok(p_bucket text) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare v_email text := lower(auth.email()); l record; v_n bigint;
begin
  if v_email is null then return true; end if;
  l := mirror.rate_limit(p_bucket);
  insert into mirror.rate_counts (actor_email, bucket, minute) values (v_email, p_bucket, date_trunc('minute', now()))
  on conflict (actor_email, bucket, minute) do update set n = mirror.rate_counts.n + 1;
  select coalesce(sum(c.n), 0) into v_n from mirror.rate_counts c
   where c.actor_email = v_email and c.bucket = p_bucket and c.minute > now() - make_interval(mins => l.minutes);
  if random() < 0.01 then delete from mirror.rate_counts where minute < now() - interval '2 days'; end if;
  return v_n <= l.max_n;
end $$;

create or replace function mirror.rate_message() returns text language sql immutable as $$
  select 'Too many in a short time. Please wait a few minutes and try again.'::text;
$$;

create or replace function mirror.rate_require(p_bucket text) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if not mirror.rate_ok(p_bucket) then raise exception '%', mirror.rate_message() using errcode = '54000'; end if;
end $$;

-- a member's refusal for the limit goes to the audit log at most once per 10 minutes per sign-in
create or replace function mirror.rate_refused(p_individual uuid, p_org uuid, p_role text, p_category text, p_table text, p_row text) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if not exists (select 1 from mirror.audit_logs a where a.actor_email = lower(auth.email()) and a.reason = 'rate_limit'
                 and a.at > now() - interval '10 minutes') then
    perform mirror.audit_refused(p_individual, p_org, p_role, p_category, p_table, p_row, 'rate_limit');
  end if;
end $$;

revoke all on function mirror.rate_limit(text), mirror.rate_ok(text), mirror.rate_message(), mirror.rate_require(text),
  mirror.rate_refused(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function mirror.rate_limit(text), mirror.rate_ok(text), mirror.rate_message(), mirror.rate_require(text),
  mirror.rate_refused(uuid, uuid, text, text, text, text) to service_role;

CREATE OR REPLACE FUNCTION mirror.allowed(p_individual uuid, p_category text, p_action text, p_org uuid DEFAULT NULL::uuid, p_table text DEFAULT NULL::text, p_row text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_email text := lower(auth.email());
  v_sensitive boolean := p_category not in ('general', 'safety_flag', 'organization', 'audit');
  v_member boolean := false;
  v_org uuid;
  v_role text;
  v_probe boolean := p_table is not distinct from '_probe';   -- quiet: a permission probe, never logged
  m record;
  p mirror.role_permissions;
begin
  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'Sign-in required.');
  end if;
  if not mirror.session_ok() then
    return jsonb_build_object('ok', false, 'reason', mirror.session_message());
  end if;
  if public.autopay_view_as_session() then
    if not v_probe then perform mirror.audit_refused(p_individual, p_org, 'view_as', p_category, p_table, p_row, 'view_as'); end if;
    return jsonb_build_object('ok', false, 'reason', 'Not available while viewing as someone else.');
  end if;

  -- the person themself
  if exists (select 1 from mirror.individuals i where i.id = p_individual and i.auth_email = v_email) then
    select * into p from mirror.role_permissions where role = 'self' and category = p_category and action = p_action;
    if found then
      if not v_probe and p_action = 'edit' and not mirror.rate_ok('edit') then
        return jsonb_build_object('ok', false, 'role', 'self', 'reason', mirror.rate_message());
      end if;
      return jsonb_build_object('ok', true, 'role', 'self');
    end if;
    return jsonb_build_object('ok', false, 'role', 'self', 'reason', 'Not allowed.');
  end if;

  -- a member of an organization that works with the person (active link only)
  for m in
    select om.role, om.organization_id
    from mirror.organization_members om
    join mirror.organizations o on o.id = om.organization_id and o.active
    join mirror.organization_individuals oi on oi.organization_id = om.organization_id and oi.individual_id = p_individual and oi.status = 'active'
    where om.auth_email = v_email and om.active and (p_org is null or om.organization_id = p_org)
    order by case om.role when 'org_admin' then 1 when 'coordinator' then 2 else 3 end
  loop
    v_member := true;
    if v_org is null then v_org := m.organization_id; v_role := m.role; end if;
    if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
      if not v_probe then perform mirror.audit_refused(p_individual, m.organization_id, m.role, p_category, p_table, p_row, 'no_authenticator'); end if;
      return jsonb_build_object('ok', false, 'role', m.role, 'reason', 'Enter your authenticator code first.');
    end if;
    select * into p from mirror.role_permissions where role = m.role and category = p_category and action = p_action;
    continue when not found;
    if p.needs_consent and not exists (
         select 1 from mirror.consents c
         where c.individual_id = p_individual and c.organization_id = m.organization_id and c.category = p_category
           and c.revoked_at is null and (c.expires_on is null or c.expires_on >= current_date)
           and (p_action = 'view' or c.access = 'edit')) then
      continue;
    end if;
    if not v_probe and not mirror.rate_ok(case when p_action = 'edit' then 'edit' else 'look' end) then
      perform mirror.rate_refused(p_individual, m.organization_id, m.role, p_category, p_table, p_row);
      return jsonb_build_object('ok', false, 'role', m.role, 'reason', mirror.rate_message());
    end if;
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit(p_individual, m.organization_id, m.role, p_action, p_category, p_table, p_row, null); end if;
    end if;
    return jsonb_build_object('ok', true, 'role', m.role, 'organization_id', m.organization_id);
  end loop;

  if v_member then
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit_refused(p_individual, v_org, v_role, p_category, p_table, p_row, 'no_consent'); end if;
    end if;
    return jsonb_build_object('ok', false, 'reason', 'The person has not shared this with your organization.');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'Not allowed.');
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_person_add(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_name text := nullif(trim(p ->> 'preferred_name'), '');
  v_legal text := nullif(trim(p ->> 'legal_name'), '');
  v_email text := nullif(lower(trim(coalesce(p ->> 'email', ''))), '');
  v_year int := nullif(p ->> 'birth_year', '')::int;
  v_me uuid;
  v_id uuid;
begin
  perform mirror.rate_require('person_add');
  if v_org is null or not mirror.coordinates(v_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Enter the name the person goes by.' using errcode = '22023'; end if;
  if length(v_name) > 120 then raise exception 'That name is too long.' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, or leave it empty.' using errcode = '22023'; end if;
  if v_year is not null and (v_year < 1900 or v_year > extract(year from now())::int) then raise exception 'Birth year looks wrong.' using errcode = '22023'; end if;
  if v_email is not null and exists (select 1 from mirror.organization_members m where m.auth_email = v_email) then
    raise exception 'That email belongs to a coordinator. Use the person''s own email.' using errcode = '22023';
  end if;
  select id into v_me from mirror.organization_members where organization_id = v_org and auth_email = lower(auth.email());

  -- The same email already has a Mirror (with another organization): link to it as an INVITATION only; never copy or overwrite
  -- their answers or details, and show this organization nothing of theirs until they accept.
  if v_email is not null then select id into v_id from mirror.individuals where auth_email = v_email; end if;
  if v_id is null then
    insert into mirror.individuals (auth_email, preferred_name, legal_name, birth_year, created_by_org)
    values (v_email, v_name, v_legal, v_year, v_org) returning id into v_id;
  end if;
  if exists (select 1 from mirror.organization_individuals where organization_id = v_org and individual_id = v_id) then
    raise exception 'This person is already on your list.' using errcode = '23505';
  end if;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, primary_member_id, invited_name)
  values (v_org, v_id, case when v_email is null then 'active' else 'invited' end, current_date, v_me, v_name);
  perform mirror.audit(v_id, v_org, mirror.my_role(v_org), 'edit', 'general', 'organization_individuals', v_id::text);
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_referral_send(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare x mirror.referrals; g jsonb; v_ref uuid;
begin
  perform mirror.rate_require('referral_send');
  select * into x from mirror.referrals where id = p_id;
  if not found then raise exception 'That referral is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(x.individual_id, x.category, 'edit', x.organization_id, 'referrals', x.id::text);
  if (g ->> 'role') = 'self' then
    raise exception 'Someone from the organization makes the referral after you agree.' using errcode = '42501';
  end if;
  if x.status <> 'consented' then raise exception 'The person has not agreed to this referral (or it is closed).' using errcode = '22023'; end if;
  if coalesce(public.chpms_role(), 'navigator_preview') not in ('staff', 'field', 'navigator') then
    raise exception 'Referrals are made by office staff, field staff or an active Housing Navigator.' using errcode = '42501';
  end if;
  v_ref := public.chpms_referral_save(jsonb_build_object('org_id', x.chpms_org_id, 'program_id', x.chpms_program_id,
    'first_name', x.first_name, 'last_name', x.last_name, 'phone', x.share_phone, 'email', x.share_email,
    'household_size', x.household_size, 'help_needed', to_jsonb(x.help_needed),
    'notes', concat_ws(E'\n', x.note_to_program, 'Consent typed in the Human Mirror on ' || to_char(x.consent_at at time zone 'America/Chicago', 'MM/DD/YYYY') || ': ' || x.consent_text),
    'consent', true, 'consent_name', x.consent_name));
  update mirror.referrals set status = 'referred', chpms_referral_id = v_ref, referred_by = lower(auth.email()), referred_at = now()
   where id = x.id returning * into x;
  perform mirror.referral_event(x.id, 'referred', 'Directory referral #' || (select c.ref_no from public.chpms_referrals c where c.id = v_ref), g ->> 'role');
  return mirror.referral_json(x);
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_org_report(p_org uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare
  v jsonb;
  v_safety int;
  tz text := 'America/Chicago';
begin
  perform mirror.rate_require('report');
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a start and an end date (the end on or after the start).' using errcode = '22023'; end if;
  if p_to - p_from > 3700 then raise exception 'Please choose a period of 10 years or less.' using errcode = '22023'; end if;

  select count(distinct oi.individual_id) into v_safety
    from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
   where oi.organization_id = p_org and oi.status in ('active', 'ended') and i.safety_sensitive and mirror.known_to_org(i.id, p_org)
     and coalesce(oi.started_on, oi.created_at::date) <= p_to and (oi.ended_on is null or oi.ended_on >= p_from);

  with ppl as materialized (
    select i.id, mirror.org_sees(i.id, p_org) as ok, oi.status, oi.started_on, oi.ended_on
      from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
     where oi.organization_id = p_org and oi.status in ('active', 'ended') and not i.safety_sensitive and mirror.known_to_org(i.id, p_org)
       and coalesce(oi.started_on, oi.created_at::date) <= p_to and (oi.ended_on is null or oi.ended_on >= p_from)),
  mem as (select m.auth_email from mirror.organization_members m where m.organization_id = p_org),
  nd as (select n.*, d.title as area from mirror.needs n join ppl on ppl.id = n.individual_id and n.category = any (ppl.ok)
           join mirror.dimensions d on d.key = n.dimension_key),
  met as (select e.need_id, min((e.at at time zone tz)::date) as on_day from mirror.need_events e
            where e.to_status = 'obtained' and e.need_id in (select id from nd) group by e.need_id)
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'safety_left_out', v_safety,
    'people', jsonb_build_object(
      'worked_with', (select count(*) from ppl),
      'started', (select count(*) from ppl where ppl.started_on between p_from and p_to),
      'ended', (select count(*) from ppl where ppl.ended_on between p_from and p_to),
      'active_now', (select count(*) from ppl where ppl.status = 'active')),
    'needs', jsonb_build_object(
      'noted', (select count(*) from nd where (nd.created_at at time zone tz)::date between p_from and p_to),
      'met', (select count(*) from met where met.on_day between p_from and p_to),
      'confirmed_by_you', (select count(*) from nd where (nd.verified_at at time zone tz)::date between p_from and p_to and nd.verified_by in (select auth_email from mem)),
      'open_now', (select count(*) from nd where nd.status in ('identified', 'planning', 'in_progress')),
      'by_area', coalesce((select jsonb_agg(jsonb_build_object('area', z.area, 'noted', z.noted, 'met', z.met) order by z.area) from (
          select nd.area,
                 count(*) filter (where (nd.created_at at time zone tz)::date between p_from and p_to) as noted,
                 count(*) filter (where met.on_day between p_from and p_to) as met
            from nd left join met on met.need_id = nd.id group by nd.area) z where z.noted + z.met > 0), '[]'::jsonb)),
    'plans', jsonb_build_object(
      'goals_reached', (select count(*) from mirror.goals g join ppl on ppl.id = g.individual_id and g.category = any (ppl.ok)
                         where g.status = 'achieved' and g.achieved_on between p_from and p_to),
      'steps_done', (select count(*) from mirror.action_items a join ppl on ppl.id = a.individual_id and a.category = any (ppl.ok)
                      where a.status = 'done' and (a.done_at at time zone tz)::date between p_from and p_to),
      'milestones', (select count(*) from mirror.milestones m join ppl on ppl.id = m.individual_id and m.category = any (ppl.ok)
                      where m.achieved_on between p_from and p_to),
      'milestones_confirmed_by_you', (select count(*) from mirror.milestones m join ppl on ppl.id = m.individual_id and m.category = any (ppl.ok)
                      where (m.verified_at at time zone tz)::date between p_from and p_to and m.verified_by in (select auth_email from mem))),
    'services', coalesce((select jsonb_agg(jsonb_build_object('service', z.name, 'started', z.started, 'finished', z.finished, 'getting_it_now', z.now_)
        order by z.name) from (
        select s.name,
               count(*) filter (where e.started_on between p_from and p_to) as started,
               count(*) filter (where e.status = 'completed' and e.ended_on between p_from and p_to) as finished,
               count(*) filter (where e.status = 'active') as now_
          from mirror.service_enrollments e join mirror.services s on s.id = e.service_id
          join ppl on ppl.id = e.individual_id and e.category = any (ppl.ok)
         where e.organization_id = p_org group by s.name) z where z.started + z.finished + z.now_ > 0), '[]'::jsonb),
    'appointments', (select jsonb_build_object('total', count(*), 'happened', count(*) filter (where a.status = 'done'),
          'cancelled', count(*) filter (where a.status = 'cancelled'), 'did_not_happen', count(*) filter (where a.status = 'not_happened'),
          'coming_up', count(*) filter (where a.status = 'scheduled'))
        from mirror.appointments a join ppl on ppl.id = a.individual_id and a.category = any (ppl.ok)
       where a.organization_id = p_org and (a.starts_at at time zone tz)::date between p_from and p_to),
    'contacts', (select jsonb_build_object('total', count(*), 'visits', count(*) filter (where x.kind = 'visit'), 'calls', count(*) filter (where x.kind = 'call'),
          'messages', count(*) filter (where x.kind = 'message'), 'meetings', count(*) filter (where x.kind = 'meeting'), 'other', count(*) filter (where x.kind = 'other'))
        from mirror.interactions x join ppl on ppl.id = x.individual_id and x.category = any (ppl.ok)
       where x.organization_id = p_org and x.corrects is null and (x.at at time zone tz)::date between p_from and p_to),
    'referrals', (select jsonb_build_object('made', count(*) filter (where (r.referred_at at time zone tz)::date between p_from and p_to),
          'agreed', count(*) filter (where (r.consent_at at time zone tz)::date between p_from and p_to))
        from mirror.referrals r join ppl on ppl.id = r.individual_id and r.category = any (ppl.ok) where r.organization_id = p_org),
    'benefits', (select jsonb_build_object('applied', count(*) filter (where b.applied_on between p_from and p_to),
          'approved', count(*) filter (where b.approved_on between p_from and p_to))
        from mirror.benefit_records b join ppl on ppl.id = b.individual_id and 'financial' = any (ppl.ok)),
    'questions_together', (select count(*) from mirror.assessment_responses x join mirror.assessments ax on ax.id = x.assessment_id
        join ppl on ppl.id = ax.individual_id join mirror.reflection_questions q on q.id = x.question_id and q.category = any (ppl.ok)
       where x.answered_by_role <> 'self' and x.answered_by in (select auth_email from mem) and (x.answered_at at time zone tz)::date between p_from and p_to),
    'goods', jsonb_build_object(
      'to_people', (select coalesce(sum(g.quantity), 0) from mirror.inventory_given g join ppl on ppl.id = g.individual_id
                     where g.organization_id = p_org and g.returned_at is null and g.given_on between p_from and p_to),
      'outside_the_mirror', (select coalesce(sum(g.quantity), 0) from mirror.inventory_given g
                     where g.organization_id = p_org and g.individual_id is null and g.returned_at is null and g.given_on between p_from and p_to),
      'by_kind', coalesce((select jsonb_agg(jsonb_build_object('kind', z.category, 'items', z.n) order by z.category) from (
          select i.category, sum(g.quantity) as n from mirror.inventory_given g join mirror.inventory_items i on i.id = g.item_id
           where g.organization_id = p_org and g.returned_at is null and g.given_on between p_from and p_to
             and (g.individual_id is null or g.individual_id in (select id from ppl)) group by i.category) z), '[]'::jsonb)))
  into v;

  perform mirror.audit(null, p_org, coalesce(mirror.my_role(p_org), 'coordinator'), 'report', 'organization', 'reports',
                       to_char(p_from, 'YYYY-MM-DD') || '..' || to_char(p_to, 'YYYY-MM-DD'));
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_platform_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare v jsonb;
begin
  perform mirror.rate_require('platform');
  if not coalesce(mirror.is_platform_admin(), false) then
    raise exception '2nd Chance platform admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'people', jsonb_build_object(
      'total', (select count(*) from mirror.individuals),
      'with_sign_in_email', (select count(*) from mirror.individuals where auth_email is not null),
      'safety_mode', (select count(*) from mirror.individuals where safety_sensitive),
      'deletion_requested', (select count(*) from mirror.individuals where deletion_requested_at is not null)),
    'members', coalesce((select jsonb_agg(jsonb_build_object('role', z.role, 'active', z.active, 'with_authenticator', z.mfa) order by z.role) from (
        select m.role, count(*) filter (where m.active) as active,
               count(*) filter (where m.active and exists (select 1 from auth.users u join auth.mfa_factors f on f.user_id = u.id
                                 where lower(u.email) = m.auth_email and f.status = 'verified')) as mfa
          from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active group by m.role) z), '[]'::jsonb),
    'organizations', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'kind', o.kind, 'active', o.active,
        'members', (select count(*) from mirror.organization_members m where m.organization_id = o.id and m.active),
        'people', (select count(*) from mirror.organization_individuals oi where oi.organization_id = o.id and oi.status = 'active'))
        order by o.is_platform_owner desc, o.name) from mirror.organizations o), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('role', p.role, 'category', p.category, 'action', p.action) order by p.role, p.category, p.action)
        from mirror.role_permissions p), '[]'::jsonb),
    'sharing', coalesce((select jsonb_agg(jsonb_build_object('organization', z.name, 'topic', z.category, 'access', z.access, 'people', z.n,
        'ending_in_30_days', z.ending) order by z.name, z.category, z.access) from (
        select o.name, c.category, c.access, count(distinct c.individual_id) as n,
               count(distinct c.individual_id) filter (where c.expires_on between current_date and current_date + 30) as ending
          from mirror.consents c join mirror.organizations o on o.id = c.organization_id
         where c.revoked_at is null and (c.expires_on is null or c.expires_on >= current_date)
         group by o.name, c.category, c.access) z), '[]'::jsonb),
    'email', jsonb_build_object(
      'turned_off', jsonb_build_object(
        'referral', (select count(*) from mirror.profiles p where p.notification_prefs ->> 'referral' = 'false'),
        'appointment', (select count(*) from mirror.profiles p where p.notification_prefs ->> 'appointment' = 'false'),
        'action', (select count(*) from mirror.profiles p where p.notification_prefs ->> 'action' = 'false')),
      'outbox', coalesce((select jsonb_agg(jsonb_build_object('kind', z.kind, 'waiting', z.waiting, 'sent', z.sent, 'failed', z.failed) order by z.kind) from (
          select e.kind, count(*) filter (where e.sent_at is null and e.error is null) as waiting, count(*) filter (where e.sent_at is not null) as sent,
                 count(*) filter (where e.sent_at is null and e.error is not null) as failed
            from public.email_outbox e where e.kind like 'mirror%' group by e.kind) z), '[]'::jsonb)),
    'settings', coalesce((select jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value) order by s.key)
        from public.portal_settings s where s.key like 'mirror%'), '[]'::jsonb),
    'deletions', coalesce((select jsonb_agg(jsonb_build_object('code', left(md5(i.id::text), 6), 'requested_on', (i.deletion_requested_at)::date,
        'due_on', (i.deletion_requested_at + interval '30 days')::date) order by i.deletion_requested_at)
        from mirror.individuals i where i.deletion_requested_at is not null), '[]'::jsonb),
    'today', current_date)
  into v;
  perform mirror.audit(null, null, 'platform_admin', 'view', 'organization', 'platform_overview', null);
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.mirror_platform_audit(p_org uuid DEFAULT NULL::uuid, p_before bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare v_rows jsonb;
begin
  perform mirror.rate_require('platform');
  if not coalesce(mirror.is_platform_admin(), false) then
    raise exception '2nd Chance platform admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'at', a.at, 'organization', o.name,
      'who', coalesce(om.name, pa.name, case when a.actor_role = 'self' then 'The person' when a.actor_role = 'view_as' then 'Office (view as)'
                                              else 'Someone no longer listed' end),
      'role', a.actor_role, 'action', a.action, 'category', a.category, 'what', a.table_name, 'reason', a.reason,
      'person', case when a.individual_id is not null then 'Person ' || left(md5(a.individual_id::text), 6) end) order by a.id desc), '[]'::jsonb)
    into v_rows
    from (select * from mirror.audit_logs x where (p_org is null or x.organization_id = p_org) and (p_before is null or x.id < p_before)
            order by x.id desc limit 100) a
    left join mirror.organizations o on o.id = a.organization_id
    left join mirror.organization_members om on om.organization_id = a.organization_id and om.auth_email = a.actor_email
    left join mirror.platform_admins pa on pa.auth_email = a.actor_email and om.name is null;
  perform mirror.audit(null, p_org, 'platform_admin', 'view', 'audit', 'audit_logs', null);
  return jsonb_build_object('rows', v_rows, 'more', jsonb_array_length(v_rows) = 100);
end $function$;
