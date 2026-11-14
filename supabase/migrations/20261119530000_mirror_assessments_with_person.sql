-- The Human Mirror Phase 8, T8.3: assessments with the person (Stephen 11/13/2026 "go to the next task in building the mirror";
-- handoff step 10). Database part.
--
-- Going over the questions WITH the person already works: a coordinator with the person's "see and change" for a topic opens a
-- question set on the one-person overview and saves the person's answers (mirror_answer_save with p_individual; each answer is marked
-- as saved by the coordinator, and the person sees "by your coordinator"). What was missing is the review: which question sets this
-- organization has gone over with each person, when, and what the person changed on their own since.
--
-- Rules
--   * Coordinators and organization admins of the organization only, with the authenticator (mirror.coordinates). Volunteers: no.
--   * Only people this organization works with now (active) and knows (mirror.known_to_org).
--   * Counts and dates only. No answer text, no earlier answers (earlier answers are for the person only: Stephen 11/12, gap item 12,
--     migration 20261119271000). Nothing is counted in a topic the organization may not see for that person (no hidden counts;
--     T6.1 finding 1); a set with questions the person keeps private only says so, without a number.
--   * "Together" = an answer saved by a member of THIS organization (not by the person). "Since" = current answers the person saved
--     themselves after the organization's last time together on that set.
--   * Each private topic counted for a person is logged as a look (table 'workspace_assessments'), so the person sees it under
--     "Who looked", as the people list does (T8.1).
--   * No new tables. Functions only; signed-in users only (anon none).

-- per question set, for one person and one organization, over the topics p_ok
create or replace function mirror.assess_review_sets(p_individual uuid, p_org uuid, p_ok text[]) returns table (
  set_key text, kind text, title text, sort int, questions bigint, answered bigint, help bigint, with_you bigint,
  last_together timestamptz, times_together bigint, since_together bigint, last_answer timestamptz, private_unshared boolean, cats text[])
language sql stable security definer set search_path = mirror, public as $$
  with members as (select m.auth_email from mirror.organization_members m where m.organization_id = p_org),
  resp as (
    select s.id as set_id, q.category, x.state, x.answered_at, x.superseded_at, x.answered_by_role,
           (x.answered_by_role <> 'self' and x.answered_by in (select auth_email from members)) as by_org
      from mirror.assessment_responses x
      join mirror.assessments a on a.id = x.assessment_id
      join mirror.question_sets s on s.id = a.set_id
      join mirror.reflection_questions q on q.id = x.question_id
     where a.individual_id = p_individual and q.active and q.category = any (p_ok)),
  agg as (
    select r.set_id,
           count(*) filter (where r.superseded_at is null) as answered,
           count(*) filter (where r.superseded_at is null and r.state = 'needs_help') as help,
           count(*) filter (where r.superseded_at is null and r.by_org) as with_you,
           max(r.answered_at) filter (where r.by_org) as last_together,
           count(distinct (r.answered_at at time zone 'America/Chicago')::date) filter (where r.by_org) as times_together,
           max(r.answered_at) filter (where r.superseded_at is null) as last_answer,
           array_agg(distinct r.category) filter (where r.superseded_at is null) as cats
      from resp r group by r.set_id)
  select s.key, s.kind, s.title, s.sort,
         (select count(*) from mirror.reflection_questions q where q.set_id = s.id and q.active and q.category = any (p_ok)),
         coalesce(g.answered, 0), coalesce(g.help, 0), coalesce(g.with_you, 0), g.last_together, coalesce(g.times_together, 0),
         case when g.last_together is null then null else
           (select count(*) from resp r where r.set_id = s.id and r.superseded_at is null and r.answered_by_role = 'self'
                                          and r.answered_at > g.last_together) end,
         g.last_answer,
         exists (select 1 from mirror.reflection_questions q where q.set_id = s.id and q.active and not (q.category = any (p_ok))),
         coalesce(g.cats, '{}')
    from mirror.question_sets s
    left join agg g on g.set_id = s.id
   where s.active
     and exists (select 1 from mirror.reflection_questions q where q.set_id = s.id and q.active and q.category = any (p_ok));
$$;

-- p_individual null: one row per person (totals). p_individual set: that person's question sets, one row each.
create or replace function public.mirror_assessments_review(p_org uuid, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  r record;
  v_ok text[];
  v_cats text[];
  v_out jsonb := '[]'::jsonb;
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;

  if p_individual is not null then
    if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                   and oi.status = 'active') or not mirror.known_to_org(p_individual, p_org) then
      raise exception 'That person is not on your organization''s list.' using errcode = '42501';
    end if;
    v_ok := mirror.org_sees(p_individual, p_org);
    if cardinality(v_ok) = 0 then return jsonb_build_object('sets', '[]'::jsonb, 'shared', false); end if;
    select coalesce(jsonb_agg(jsonb_build_object('key', t.set_key, 'kind', t.kind, 'title', t.title, 'questions', t.questions,
        'answered', t.answered, 'help', t.help, 'with_you', t.with_you, 'last_together', t.last_together, 'times_together', t.times_together,
        'since_together', t.since_together, 'last_answer', t.last_answer, 'private_unshared', t.private_unshared)
        order by t.kind, t.sort, t.set_key), '[]'::jsonb),
      (select array_agg(distinct c) from mirror.assess_review_sets(p_individual, p_org, v_ok) z, unnest(z.cats) c)
      into v_out, v_cats
      from mirror.assess_review_sets(p_individual, p_org, v_ok) t;
    perform mirror.log_private_looks(p_individual, p_org, v_cats, 'workspace_assessments');
    return jsonb_build_object('sets', v_out, 'shared', true);
  end if;

  for r in select i.id, i.preferred_name, i.safety_sensitive from mirror.organization_individuals oi
             join mirror.individuals i on i.id = oi.individual_id
           where oi.organization_id = p_org and oi.status = 'active' and mirror.known_to_org(i.id, p_org) loop
    v_ok := mirror.org_sees(r.id, p_org);
    if cardinality(v_ok) = 0 then
      v_out := v_out || jsonb_build_object('id', r.id, 'name', r.preferred_name, 'safety_sensitive', r.safety_sensitive, 'shared', false);
      continue;
    end if;
    v_out := v_out || (select jsonb_build_object('id', r.id, 'name', r.preferred_name, 'safety_sensitive', r.safety_sensitive, 'shared', true,
        'sets_started', count(*) filter (where t.answered > 0),
        'sets_together', count(*) filter (where t.last_together is not null),
        'answered', coalesce(sum(t.answered), 0), 'help', coalesce(sum(t.help), 0), 'with_you', coalesce(sum(t.with_you), 0),
        'since_together', coalesce(sum(t.since_together), 0),
        'last_together', max(t.last_together), 'last_answer', max(t.last_answer))
      from mirror.assess_review_sets(r.id, p_org, v_ok) t);
    select array_agg(distinct c) into v_cats from mirror.assess_review_sets(r.id, p_org, v_ok) z, unnest(z.cats) c;
    perform mirror.log_private_looks(r.id, p_org, v_cats, 'workspace_assessments');
  end loop;
  return jsonb_build_object('people', v_out);
end $$;

revoke all on function mirror.assess_review_sets(uuid, uuid, text[]) from public, anon, authenticated;
grant execute on function mirror.assess_review_sets(uuid, uuid, text[]) to service_role;
revoke all on function public.mirror_assessments_review(uuid, uuid) from public, anon;
grant execute on function public.mirror_assessments_review(uuid, uuid) to authenticated, service_role;
