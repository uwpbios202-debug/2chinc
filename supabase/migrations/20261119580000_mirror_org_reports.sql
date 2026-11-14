-- The Human Mirror Phase 8, T8.8: outcomes and reports (Stephen 11/13/2026 "go"; handoff step 15). Database part.
--
-- Rules (D-39, defaults chosen by Claude)
--   (a) One report per organization and period (from - to, inclusive): counts only. No names, no person ids, no score of anyone (D-09).
--   (b) Coordinators and organization admins of the organization (with the authenticator). Volunteers and other organizations: no.
--   (c) People in safety mode are left out of every count (P2-06); the report says how many were left out.
--   (d) Only people this organization works with or worked with during the period, and knows. A private topic is counted only for
--       people who share it with this organization now (no hidden counts, T6.1 finding 1); the organization's own records
--       (services, appointments, notes, referrals) follow the same rule by their topic.
--   (e) Running a report is written once to the organization's audit log (no person named; a count is not a look at a person).
--   (f) The page can show numbers under 5 as "fewer than 5" for reports shared outside the organization, and download a CSV.
-- No new tables.

create or replace function public.mirror_org_report(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v jsonb;
  v_safety int;
  tz text := 'America/Chicago';
begin
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
end $$;

revoke all on function public.mirror_org_report(uuid, date, date) from public, anon;
grant execute on function public.mirror_org_report(uuid, date, date) to authenticated, service_role;
