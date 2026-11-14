-- The Human Mirror T6.3, part 2 (Stephen 11/13/2026: "should the goals page suggest goals from the person's answers to
-- 'Who do I want to become?'? YES"; handoff "PHASE 6 FINISH" step 3): goals suggested from the Vision reflection, like needs and
-- strengths. Nothing is created until the person taps "Add as a goal"; "Not now" hides a suggestion.
--
-- Rules
--   * Source: the person's CURRENT answers to the Vision reflection (set reflection_vision), answered (not skipped), not empty.
--     One suggestion per question, key vision:<question>.
--   * Title: the person's own words (up to 200 letters; a longer answer is cut at 199 and marked with "…"); the money question
--     becomes "Earn about $N a month". The person may change the words before adding (1-200 letters). The whole answer is kept as
--     the goal's details (up to 2,000 letters).
--   * Area of life: from the question (where to live / home -> housing, work / learning -> work, relationships, health, money ...);
--     a private question (health, money) ALWAYS lands in that topic's one area, so a private answer never becomes an everyday goal.
--     "A year from now" and "What would you like to own" have no area: the person picks one when adding.
--   * No stage is suggested (stages are the person's own labels, not deadlines). They can set one afterwards.
--   * Person only (mirror.me(): never an organization, never View as). A goal made from a suggestion remembers its key
--     (goals.from_key), so the suggestion does not come back; "Not now" is kept in mirror.goal_suggestion_dismissals.
-- New table carries explicit grants (CLAUDE.md 10/30/2026 rule): service_role only; authenticated and anon none.

alter table mirror.goals add column from_key text check (from_key is null or length(from_key) <= 200);

create table mirror.goal_suggestion_dismissals (
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  from_key text not null check (length(from_key) <= 200),
  at timestamptz not null default now(),
  primary key (individual_id, from_key)
);
alter table mirror.goal_suggestion_dismissals enable row level security;
revoke all on mirror.goal_suggestion_dismissals from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.goal_suggestion_dismissals to service_role;

-- the area of life a Vision question points to (null: the person picks)
create or replace function mirror.vision_dimension(p_question text) returns text
language sql immutable set search_path = mirror, public as $$
  select case p_question
    when 'person' then 'development' when 'where_live' then 'housing' when 'home' then 'housing'
    when 'work' then 'work' when 'learn' then 'work' when 'income' then 'finances' when 'health' then 'physical_health'
    when 'relationships' then 'relationships' when 'experiences' then 'development'
    when 'fulfilled' then 'purpose' when 'proud_five_years' then 'purpose' end;
$$;

-- every open goal suggestion for one person (no permission check here: callers pass mirror.me())
create or replace function mirror.goal_suggestions_for(v uuid) returns table (from_key text, title text, detail text, dimension_key text, source text, sort int)
language sql stable set search_path = mirror, public as $$
  select 'vision:' || ca.question_key,
    case when q.answer_type = 'money' then 'Earn about ' || to_char((ca.value #>> '{}')::numeric, 'FM$999,999,990') || ' a month'
         when length(btrim(ca.value #>> '{}')) <= 200 then btrim(ca.value #>> '{}')
         else left(btrim(ca.value #>> '{}'), 199) || '…' end,
    case when q.answer_type = 'money' then null else left(btrim(ca.value #>> '{}'), 2000) end,
    case when ca.category = 'general' then mirror.vision_dimension(ca.question_key) else mirror.category_dimension(ca.category) end,
    q.prompt, q.sort
  from mirror.current_answers ca
  join mirror.question_sets qs on qs.key = ca.set_key
  join mirror.reflection_questions q on q.set_id = qs.id and q.key = ca.question_key
  where ca.individual_id = v and ca.set_key = 'reflection_vision' and ca.state = 'answered' and q.active
    and jsonb_typeof(ca.value) in ('string', 'number') and length(btrim(ca.value #>> '{}')) > 0
    and case when q.answer_type = 'money' then (ca.value #>> '{}')::numeric > 0 else true end
    and not exists (select 1 from mirror.goals g where g.individual_id = v and g.from_key = 'vision:' || ca.question_key)
    and not exists (select 1 from mirror.goal_suggestion_dismissals x where x.individual_id = v and x.from_key = 'vision:' || ca.question_key);
$$;

create or replace function public.mirror_goal_suggestions() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('key', x.from_key, 'title', x.title, 'detail', x.detail, 'dimension', x.dimension_key,
      'dimension_title', d.title, 'private', mirror.dimension_category(x.dimension_key) <> 'general', 'source', x.source) order by x.sort)
    from mirror.goal_suggestions_for(v) x left join mirror.dimensions d on d.key = x.dimension_key), '[]'::jsonb);
end $$;

-- "Add as a goal": p_title = the person's words (empty: the suggested words); p_dimension only when the suggestion has no area
create or replace function public.mirror_goal_add_suggested(p_key text, p_title text default null, p_dimension text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.me();
  x record;
  v_dim text;
  v_title text;
  g mirror.goals;
begin
  select * into x from mirror.goal_suggestions_for(v) s where s.from_key = p_key;
  if not found then raise exception 'That suggestion is no longer there.' using errcode = 'P0002'; end if;
  v_dim := coalesce(x.dimension_key, p_dimension);
  if v_dim is null or not exists (select 1 from mirror.dimensions d where d.key = v_dim) then
    raise exception 'Choose an area of life for this goal.' using errcode = '22023';
  end if;
  v_title := coalesce(nullif(btrim(coalesce(p_title, '')), ''), x.title);
  if length(v_title) > 200 then raise exception 'Please keep the goal to 200 letters; your whole answer is kept in the details.' using errcode = '22023'; end if;
  perform mirror.require(v, mirror.dimension_category(v_dim), 'edit', null, 'goals', null);
  insert into mirror.goals (individual_id, dimension_key, category, title, detail, set_by, set_by_role, from_key)
  values (v, v_dim, mirror.dimension_category(v_dim), v_title, case when x.detail is distinct from v_title then x.detail end,
          lower(auth.email()), 'self', p_key)
  returning * into g;
  return mirror.goal_json(g);
end $$;

-- "Not now"
create or replace function public.mirror_goal_suggestion_dismiss(p_key text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if coalesce(length(p_key), 0) not between 1 and 200 then raise exception 'Unknown suggestion.' using errcode = '22023'; end if;
  insert into mirror.goal_suggestion_dismissals (individual_id, from_key) values (v, p_key) on conflict do nothing;
end $$;

-- the person's download also says which goals came from their answers (otherwise as in 20261119331000)
create or replace function public.mirror_my_export_plan() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return jsonb_build_object(
    'goals', coalesce((select jsonb_agg(jsonb_build_object('goal', g.title, 'area', d.title, 'details', g.detail, 'stage', g.stage, 'hope_by', g.hope_by,
        'status', g.status, 'achieved_on', g.achieved_on, 'set_by', g.set_by_role, 'added', g.created_at,
        'from_your_answers', g.from_key is not null) order by g.created_at)
      from mirror.goals g join mirror.dimensions d on d.key = g.dimension_key where g.individual_id = v), '[]'::jsonb),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('step', a.title, 'for_goal', (select g.title from mirror.goals g where g.id = a.goal_id),
        'for_need', (select n.title from mirror.needs n where n.id = a.need_id), 'who', case when a.who = 'me' then 'me' else a.helper end,
        'due_on', a.due_on, 'status', a.status, 'done_at', a.done_at, 'added_by', a.added_by_role) order by a.created_at)
      from mirror.action_items a where a.individual_id = v), '[]'::jsonb),
    'milestones', coalesce((select jsonb_agg(jsonb_build_object('milestone', m.title, 'details', m.detail, 'achieved_on', m.achieved_on,
        'area', (select d.title from mirror.dimensions d where d.key = m.dimension_key), 'confirmed_at', m.verified_at, 'added_by', m.added_by_role)
        order by m.achieved_on)
      from mirror.milestones m where m.individual_id = v), '[]'::jsonb),
    'goals_set_aside', coalesce((select jsonb_agg(x.from_key order by x.at) from mirror.goal_suggestion_dismissals x where x.individual_id = v), '[]'::jsonb));
end $$;

revoke all on function mirror.vision_dimension(text), mirror.goal_suggestions_for(uuid) from public, anon, authenticated;
grant execute on function mirror.vision_dimension(text), mirror.goal_suggestions_for(uuid) to service_role;
revoke all on function public.mirror_goal_suggestions(), public.mirror_goal_add_suggested(text, text, text), public.mirror_goal_suggestion_dismiss(text)
  from public, anon;
grant execute on function public.mirror_goal_suggestions(), public.mirror_goal_add_suggested(text, text, text), public.mirror_goal_suggestion_dismiss(text)
  to authenticated, service_role;
