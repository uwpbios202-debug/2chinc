-- The Human Mirror T6.4: the progress page (Stephen 11/13/2026, handoff "PHASE 6 FINISH" step 1; MASTER_ROADMAP T6.4
-- "counts per dimension (D-09), history over time").
--
-- Rules
--   * D-09: no single score of a person anywhere. Only plain counts per area of life (needs noted / met / confirmed, goals working
--     on / reached, steps done / to do, milestones, strengths), labeled for what they are ("steps done"), never a percent, rank,
--     readiness or worth. No total across areas is turned into a number about the person.
--   * History over time: the same kinds of things counted per month, last 12 months (steps done by done_at, needs got by the
--     need's "obtained" event, needs confirmed by the "verified" event, goals reached by achieved_on, milestones by achieved_on,
--     needs noted by created_at). A step that was reopened no longer counts as done (its done_at is cleared).
--   * Every count uses only the records the caller may see (the one gate: mirror.allowed / mirror.may). An area whose privacy
--     topic the caller may not see is returned as "not shared" with NO counts: nobody but the person learns whether anything is
--     hidden (T6.1 report finding 1). The history counts only visible topics too.
--   * Reads only; no new tables, so no new grants on tables (CLAUDE.md 10/30/2026 rule). The function is for signed-in users only.

create or replace function public.mirror_progress(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_ok text[] := '{}';
  c text;
  r jsonb;
  v_from date := (date_trunc('month', current_date) - interval '11 months')::date;
begin
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  -- the topics the caller may see; a look at a topic that holds records is logged, as on the plan page
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'view') then
      v_ok := v_ok || c;
      if exists (select 1 from mirror.needs where individual_id = v_id and category = c)
         or exists (select 1 from mirror.goals where individual_id = v_id and category = c)
         or exists (select 1 from mirror.action_items where individual_id = v_id and category = c)
         or exists (select 1 from mirror.milestones where individual_id = v_id and category = c)
         or exists (select 1 from mirror.strengths where individual_id = v_id and category = c) then
        perform mirror.allowed(v_id, c, 'view', null, 'progress', null);
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'self', (r ->> 'role') = 'self',
    'areas', (select jsonb_agg(x.j order by x.n) from (
      select d.n, case when mirror.dimension_category(d.key) = any (v_ok) then jsonb_build_object(
          'key', d.key, 'title', d.title, 'shared', true, 'private', mirror.dimension_category(d.key) <> 'general',
          'needs_open', (select count(*) from mirror.needs n where n.individual_id = v_id and n.dimension_key = d.key
                          and n.status in ('identified', 'planning', 'in_progress')),
          'needs_met', (select count(*) from mirror.needs n where n.individual_id = v_id and n.dimension_key = d.key
                          and n.status in ('obtained', 'verified')),
          'needs_verified', (select count(*) from mirror.needs n where n.individual_id = v_id and n.dimension_key = d.key and n.status = 'verified'),
          'goals_active', (select count(*) from mirror.goals g where g.individual_id = v_id and g.dimension_key = d.key and g.status in ('active', 'paused')),
          'goals_reached', (select count(*) from mirror.goals g where g.individual_id = v_id and g.dimension_key = d.key and g.status = 'achieved'),
          'steps_done', (select count(*) from mirror.action_items a
                          left join mirror.goals g on g.id = a.goal_id left join mirror.needs n on n.id = a.need_id
                          where a.individual_id = v_id and a.status = 'done' and coalesce(g.dimension_key, n.dimension_key) = d.key
                            and a.category = any (v_ok)),
          'steps_open', (select count(*) from mirror.action_items a
                          left join mirror.goals g on g.id = a.goal_id left join mirror.needs n on n.id = a.need_id
                          where a.individual_id = v_id and a.status = 'open' and coalesce(g.dimension_key, n.dimension_key) = d.key
                            and a.category = any (v_ok)),
          'milestones', (select count(*) from mirror.milestones m where m.individual_id = v_id and m.dimension_key = d.key and m.category = any (v_ok)),
          'strengths', (select count(*) from mirror.strengths s where s.individual_id = v_id and s.dimension_key = d.key and s.category = any (v_ok)))
        else jsonb_build_object('key', d.key, 'title', d.title, 'shared', false, 'private', true) end as j
      from mirror.dimensions d) x),
    -- records not tied to one area (a step for no goal or need, a milestone or strength with no area), visible topics only
    'no_area', jsonb_build_object(
      'steps_done', (select count(*) from mirror.action_items a where a.individual_id = v_id and a.goal_id is null and a.need_id is null
                      and a.status = 'done' and a.category = any (v_ok)),
      'steps_open', (select count(*) from mirror.action_items a where a.individual_id = v_id and a.goal_id is null and a.need_id is null
                      and a.status = 'open' and a.category = any (v_ok)),
      'milestones', (select count(*) from mirror.milestones m where m.individual_id = v_id and m.dimension_key is null and m.category = any (v_ok)),
      'strengths', (select count(*) from mirror.strengths s where s.individual_id = v_id and s.dimension_key is null and s.category = any (v_ok))),
    'history', (select jsonb_agg(jsonb_build_object('month', to_char(mo, 'YYYY-MM'),
        'needs_noted', (select count(*) from mirror.needs n where n.individual_id = v_id and n.category = any (v_ok)
                         and date_trunc('month', n.created_at)::date = mo),
        'needs_met', (select count(distinct e.need_id) from mirror.need_events e join mirror.needs n on n.id = e.need_id
                       where n.individual_id = v_id and n.category = any (v_ok) and e.to_status = 'obtained'
                         and date_trunc('month', e.at)::date = mo),
        'needs_verified', (select count(distinct e.need_id) from mirror.need_events e join mirror.needs n on n.id = e.need_id
                       where n.individual_id = v_id and n.category = any (v_ok) and e.to_status = 'verified'
                         and date_trunc('month', e.at)::date = mo),
        'steps_done', (select count(*) from mirror.action_items a where a.individual_id = v_id and a.category = any (v_ok)
                        and a.status = 'done' and date_trunc('month', a.done_at)::date = mo),
        'goals_reached', (select count(*) from mirror.goals g where g.individual_id = v_id and g.category = any (v_ok)
                           and date_trunc('month', g.achieved_on)::date = mo),
        'milestones', (select count(*) from mirror.milestones m where m.individual_id = v_id and m.category = any (v_ok)
                        and date_trunc('month', m.achieved_on)::date = mo)) order by mo)
      from generate_series(v_from, date_trunc('month', current_date)::date, interval '1 month') s(mo0), lateral (select s.mo0::date as mo) z));
end $$;

revoke all on function public.mirror_progress(uuid) from public, anon;
grant execute on function public.mirror_progress(uuid) to authenticated, service_role;
