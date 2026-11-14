-- The Human Mirror T6.3: goals, the plan, action items and milestones (Stephen 11/13/2026 "After the report begin T6.3";
-- MASTER_ROADMAP T6.3 "journey stages 1-6 as labels, not deadlines"; Mirror1 Part 3, the six stages; DATABASE_DESIGN goals,
-- action_items, milestones).
--
-- Rules
--   * A goal belongs to one area of life (mirror.dimensions); its privacy topic comes from the area (mirror.dimension_category, the
--     same helper the needs use). It may carry one of Mirror1's six stages as a LABEL (1 Immediate stabilization, 2 Establishing a
--     foundation, 3 Establishing a home, 4 Building earning capacity, 5 Developing independence, 6 Flourishing and contributing), or none.
--     "These stages are not rigid deadlines ... Multiple stages should operate concurrently": nothing checks order, nothing is late.
--     A date is the person's own "hope to by", optional, never enforced.
--   * The plan = the person's goals by stage (sitemap plan/). No separate action_plans table: a step belongs to a goal, to a need, or
--     to neither (D-28).
--   * Steps (action_items): who does it is "me" or a helper named in words (a coordinator, a sister); a step tied to a goal or need
--     takes that record's privacy topic.
--   * Milestones are accomplishments. Reaching a goal adds one by itself. An organization may confirm a milestone (same rule as
--     verifying a need, D-27).
--   * The person chooses (DATABASE_DESIGN "set_by_individual"): a coordinator with "see and change" for the topic may add and update
--     goals, steps and milestones (marked as theirs), but only the person removes them.
--   * Lists show only what the caller may see. Nobody but the person gets a count of what is hidden (T6.1 report finding 1).
--   * Every read and write passes mirror.allowed / mirror.require (the one gate).
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only; authenticated and anon none.

-- ---------------------------------------------------------------- tables
create table mirror.goals (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  dimension_key text not null references mirror.dimensions(key) on delete restrict,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  title text not null check (length(btrim(title)) between 1 and 200),
  detail text check (detail is null or length(detail) <= 2000),
  stage smallint check (stage between 1 and 6),
  hope_by date,
  status text not null default 'active' check (status in ('active', 'paused', 'achieved', 'let_go')),
  achieved_on date,
  set_by text not null,
  set_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'achieved') = (achieved_on is not null))
);
create index goals_person on mirror.goals (individual_id, status);

create table mirror.action_items (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  goal_id uuid references mirror.goals(id) on delete cascade,
  need_id uuid references mirror.needs(id) on delete cascade,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  title text not null check (length(btrim(title)) between 1 and 200),
  who text not null default 'me' check (who in ('me', 'helper')),
  helper text check (helper is null or length(helper) <= 120),
  due_on date,
  status text not null default 'open' check (status in ('open', 'done', 'dropped')),
  done_at timestamptz,
  added_by text not null,
  added_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (goal_id is null or need_id is null),
  check ((status = 'done') = (done_at is not null)),
  check (who = 'helper' or helper is null)
);
create index action_items_person on mirror.action_items (individual_id, status);
create index action_items_goal on mirror.action_items (goal_id) where goal_id is not null;
create index action_items_need on mirror.action_items (need_id) where need_id is not null;

create table mirror.milestones (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  goal_id uuid references mirror.goals(id) on delete set null,
  dimension_key text references mirror.dimensions(key) on delete restrict,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  title text not null check (length(btrim(title)) between 1 and 200),
  detail text check (detail is null or length(detail) <= 2000),
  achieved_on date not null default current_date,
  automatic boolean not null default false,          -- added when a goal was reached
  verified_at timestamptz,
  verified_by text,
  added_by text not null,
  added_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((verified_at is null) = (verified_by is null))
);
create index milestones_person on mirror.milestones (individual_id, achieved_on desc);
create unique index milestones_goal_auto on mirror.milestones (goal_id) where automatic;

create trigger goals_touch before update on mirror.goals for each row execute function mirror.touch();
create trigger action_items_touch before update on mirror.action_items for each row execute function mirror.touch();
create trigger milestones_touch before update on mirror.milestones for each row execute function mirror.touch();

-- a step tied to a goal or need belongs to the same person (the functions check it too; this keeps the tables honest)
create or replace function mirror.action_items_same_person() returns trigger language plpgsql set search_path = mirror as $$
begin
  if new.goal_id is not null and not exists (select 1 from mirror.goals g where g.id = new.goal_id and g.individual_id = new.individual_id)
     or new.need_id is not null and not exists (select 1 from mirror.needs n where n.id = new.need_id and n.individual_id = new.individual_id) then
    raise exception 'A step can only belong to the same person''s goal or need.' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger action_items_same_person before insert or update on mirror.action_items for each row execute function mirror.action_items_same_person();

create or replace function mirror.milestones_same_person() returns trigger language plpgsql set search_path = mirror as $$
begin
  if new.goal_id is not null and not exists (select 1 from mirror.goals g where g.id = new.goal_id and g.individual_id = new.individual_id) then
    raise exception 'A milestone can only belong to the same person''s goal.' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger milestones_same_person before insert or update on mirror.milestones for each row execute function mirror.milestones_same_person();

create or replace function mirror.plan_no_truncate() returns trigger language plpgsql set search_path = mirror as $$
begin
  raise exception 'Goals, steps and milestones are never emptied in bulk.' using errcode = '42501';
end $$;
create trigger goals_no_truncate before truncate on mirror.goals for each statement execute function mirror.plan_no_truncate();
create trigger action_items_no_truncate before truncate on mirror.action_items for each statement execute function mirror.plan_no_truncate();
create trigger milestones_no_truncate before truncate on mirror.milestones for each statement execute function mirror.plan_no_truncate();

-- ---------------------------------------------------------------- small helpers
create or replace function mirror.plan_date(p jsonb, k text) returns date
language plpgsql immutable set search_path = mirror, public as $$
declare v text := nullif(btrim(coalesce(p ->> k, '')), '');
begin
  if v is null then return null; end if;
  if v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Please give the date as year-month-day.' using errcode = '22023'; end if;
  return v::date;
exception when datetime_field_overflow or invalid_datetime_format then
  raise exception 'That date does not exist.' using errcode = '22023';
end $$;

create or replace function mirror.goal_json(g mirror.goals) returns jsonb
language sql stable set search_path = mirror, public as $$
  select jsonb_build_object('id', g.id, 'dimension', g.dimension_key, 'dimension_title', (select d.title from mirror.dimensions d where d.key = g.dimension_key),
    'category', g.category, 'private', g.category <> 'general', 'title', g.title, 'detail', g.detail, 'stage', g.stage, 'hope_by', g.hope_by,
    'status', g.status, 'achieved_on', g.achieved_on, 'set_by_role', g.set_by_role, 'created_at', g.created_at, 'updated_at', g.updated_at);
$$;

create or replace function mirror.action_json(a mirror.action_items) returns jsonb
language sql stable set search_path = mirror, public as $$
  select jsonb_build_object('id', a.id, 'goal_id', a.goal_id, 'need_id', a.need_id,
    'need_title', (select n.title from mirror.needs n where n.id = a.need_id),
    'category', a.category, 'private', a.category <> 'general', 'title', a.title, 'who', a.who, 'helper', a.helper, 'due_on', a.due_on,
    'status', a.status, 'done_at', a.done_at, 'added_by_role', a.added_by_role, 'created_at', a.created_at);
$$;

create or replace function mirror.milestone_json(m mirror.milestones) returns jsonb
language sql stable set search_path = mirror, public as $$
  select jsonb_build_object('id', m.id, 'goal_id', m.goal_id, 'dimension', m.dimension_key,
    'dimension_title', (select d.title from mirror.dimensions d where d.key = m.dimension_key),
    'category', m.category, 'private', m.category <> 'general', 'title', m.title, 'detail', m.detail, 'achieved_on', m.achieved_on,
    'automatic', m.automatic, 'verified', m.verified_at is not null, 'verified_at', m.verified_at, 'added_by_role', m.added_by_role);
$$;

-- ---------------------------------------------------------------- the whole plan the caller may see
create or replace function public.mirror_plan(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_ok text[] := '{}';
  v_add text[] := '{}';
  c text;
  r jsonb;
begin
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  for c in select distinct x.category from (
      select category from mirror.goals where individual_id = v_id
      union select category from mirror.action_items where individual_id = v_id
      union select category from mirror.milestones where individual_id = v_id
      union select category from mirror.needs where individual_id = v_id) x loop
    if mirror.may(v_id, c, 'view') then
      v_ok := v_ok || c;
      perform mirror.allowed(v_id, c, 'view', null, 'goals', null);
    end if;
  end loop;
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'edit') then v_add := v_add || c; end if;
  end loop;
  return jsonb_build_object(
    'self', (r ->> 'role') = 'self',
    'can_add', to_jsonb(v_add),
    'goals', coalesce((select jsonb_agg(mirror.goal_json(g) order by
        case g.status when 'active' then 0 when 'paused' then 1 when 'achieved' then 2 else 3 end, g.stage nulls last, g.created_at)
      from mirror.goals g where g.individual_id = v_id and g.category = any (v_ok)), '[]'::jsonb),
    'actions', coalesce((select jsonb_agg(mirror.action_json(a) order by
        case a.status when 'open' then 0 when 'done' then 1 else 2 end, a.due_on nulls last, a.created_at)
      from mirror.action_items a where a.individual_id = v_id and a.category = any (v_ok)), '[]'::jsonb),
    'milestones', coalesce((select jsonb_agg(mirror.milestone_json(m) order by m.achieved_on desc, m.created_at desc)
      from mirror.milestones m where m.individual_id = v_id and m.category = any (v_ok)), '[]'::jsonb),
    -- open needs the caller may see, to tie a step to (titles only)
    'needs', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'private', n.category <> 'general') order by n.created_at)
      from mirror.needs n where n.individual_id = v_id and n.status in ('identified', 'planning', 'in_progress', 'obtained')
       and n.category = any (v_ok)), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- goals
-- p: dimension, title, detail, stage (1-6 or empty), hope_by (yyyy-mm-dd or empty), status (active, paused, achieved, let_go)
create or replace function public.mirror_goal_save(p_id uuid, p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  g mirror.goals;
  gate jsonb;
  v_id uuid;
  v_dim text := p ->> 'dimension';
  v_cat text;
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_detail text := nullif(btrim(coalesce(p ->> 'detail', '')), '');
  v_stage smallint;
  v_hope date := mirror.plan_date(p, 'hope_by');
  v_status text := coalesce(nullif(p ->> 'status', ''), 'active');
begin
  if not exists (select 1 from mirror.dimensions d where d.key = v_dim) then raise exception 'Choose an area of life for this goal.' using errcode = '22023'; end if;
  if length(v_title) = 0 then raise exception 'Say your goal in a few words.' using errcode = '22023'; end if;
  if length(v_title) > 200 then raise exception 'Please keep the goal to 200 letters; add more in the details.' using errcode = '22023'; end if;
  if length(coalesce(v_detail, '')) > 2000 then raise exception 'The details are too long (2,000 letters at most).' using errcode = '22023'; end if;
  if nullif(p ->> 'stage', '') is not null then
    if (p ->> 'stage') !~ '^[1-6]$' then raise exception 'Unknown stage.' using errcode = '22023'; end if;
    v_stage := (p ->> 'stage')::smallint;
  end if;
  if v_status not in ('active', 'paused', 'achieved', 'let_go') then raise exception 'Unknown goal status.' using errcode = '22023'; end if;
  v_cat := mirror.dimension_category(v_dim);

  if p_id is null then
    v_id := mirror.target_individual(p_individual);
    gate := mirror.require(v_id, v_cat, 'edit', null, 'goals', null);
    insert into mirror.goals (individual_id, dimension_key, category, title, detail, stage, hope_by, status, achieved_on, set_by, set_by_role)
    values (v_id, v_dim, v_cat, v_title, v_detail, v_stage, v_hope, v_status, case when v_status = 'achieved' then current_date end,
            lower(auth.email()), gate ->> 'role')
    returning * into g;
  else
    select * into g from mirror.goals where id = p_id;
    if not found or (p_individual is not null and p_individual <> g.individual_id) then raise exception 'That goal is not available.' using errcode = 'P0002'; end if;
    gate := mirror.require(g.individual_id, g.category, 'edit', null, 'goals', g.id::text);
    if v_cat <> g.category then perform mirror.require(g.individual_id, v_cat, 'edit', null, 'goals', g.id::text); end if;
    update mirror.goals set dimension_key = v_dim, category = v_cat, title = v_title, detail = v_detail, stage = v_stage, hope_by = v_hope,
        status = v_status, achieved_on = case when v_status = 'achieved' then coalesce(g.achieved_on, current_date) end
     where id = g.id returning * into g;
    -- steps take the goal's topic with it when the area changes
    update mirror.action_items set category = v_cat where goal_id = g.id and category <> v_cat;
  end if;

  -- reaching a goal records a milestone, once
  if g.status = 'achieved' and not exists (select 1 from mirror.milestones m where m.goal_id = g.id and m.automatic) then
    insert into mirror.milestones (individual_id, goal_id, dimension_key, category, title, achieved_on, automatic, added_by, added_by_role)
    values (g.individual_id, g.id, g.dimension_key, g.category, g.title, g.achieved_on, true, lower(auth.email()), gate ->> 'role');
  end if;
  return mirror.goal_json(g);
end $$;

-- ---------------------------------------------------------------- steps (action items)
-- p: title, goal_id or need_id (or neither), who (me, helper), helper (words), due_on, status (open, done, dropped)
create or replace function public.mirror_action_save(p_id uuid, p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  a mirror.action_items;
  v_id uuid;
  v_goal uuid := nullif(p ->> 'goal_id', '')::uuid;
  v_need uuid := nullif(p ->> 'need_id', '')::uuid;
  v_cat text := 'general';
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_who text := coalesce(nullif(p ->> 'who', ''), 'me');
  v_helper text := nullif(btrim(coalesce(p ->> 'helper', '')), '');
  v_due date := mirror.plan_date(p, 'due_on');
  v_status text := coalesce(nullif(p ->> 'status', ''), 'open');
  gate jsonb;
begin
  if length(v_title) = 0 then raise exception 'Say the step in a few words.' using errcode = '22023'; end if;
  if length(v_title) > 200 then raise exception 'Please keep the step to 200 letters.' using errcode = '22023'; end if;
  if v_who not in ('me', 'helper') then raise exception 'Unknown "who does it".' using errcode = '22023'; end if;
  if v_who = 'helper' and v_helper is null then raise exception 'Say who is helping with this step.' using errcode = '22023'; end if;
  if v_who = 'me' then v_helper := null; end if;
  if length(coalesce(v_helper, '')) > 120 then raise exception 'Please keep the helper''s name to 120 letters.' using errcode = '22023'; end if;
  if v_status not in ('open', 'done', 'dropped') then raise exception 'Unknown step status.' using errcode = '22023'; end if;
  if v_goal is not null and v_need is not null then raise exception 'A step belongs to one goal or one need, not both.' using errcode = '22023'; end if;

  if p_id is null then v_id := mirror.target_individual(p_individual);
  else
    select * into a from mirror.action_items where id = p_id;
    if not found or (p_individual is not null and p_individual <> a.individual_id) then raise exception 'That step is not available.' using errcode = 'P0002'; end if;
    v_id := a.individual_id;
    perform mirror.require(v_id, a.category, 'edit', null, 'action_items', a.id::text);
  end if;
  if v_goal is not null then
    select g.category into v_cat from mirror.goals g where g.id = v_goal and g.individual_id = v_id;
    if not found then raise exception 'That goal is not available.' using errcode = 'P0002'; end if;
  elsif v_need is not null then
    select n.category into v_cat from mirror.needs n where n.id = v_need and n.individual_id = v_id;
    if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  end if;
  gate := mirror.require(v_id, v_cat, 'edit', null, 'action_items', p_id::text);

  if p_id is null then
    insert into mirror.action_items (individual_id, goal_id, need_id, category, title, who, helper, due_on, status, done_at, added_by, added_by_role)
    values (v_id, v_goal, v_need, v_cat, v_title, v_who, v_helper, v_due, v_status, case when v_status = 'done' then now() end,
            lower(auth.email()), gate ->> 'role')
    returning * into a;
  else
    update mirror.action_items set goal_id = v_goal, need_id = v_need, category = v_cat, title = v_title, who = v_who, helper = v_helper,
        due_on = v_due, status = v_status, done_at = case when v_status = 'done' then coalesce(a.done_at, now()) end
     where id = a.id returning * into a;
  end if;
  return mirror.action_json(a);
end $$;

-- ---------------------------------------------------------------- milestones
-- p: title, detail, achieved_on, goal_id (optional), dimension (optional; taken from the goal when there is one)
create or replace function public.mirror_milestone_save(p_id uuid, p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  m mirror.milestones;
  v_id uuid;
  v_goal uuid := nullif(p ->> 'goal_id', '')::uuid;
  v_dim text := nullif(p ->> 'dimension', '');
  v_cat text;
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_detail text := nullif(btrim(coalesce(p ->> 'detail', '')), '');
  v_on date := coalesce(mirror.plan_date(p, 'achieved_on'), current_date);
  gate jsonb;
begin
  if length(v_title) = 0 then raise exception 'Say what you did in a few words.' using errcode = '22023'; end if;
  if length(v_title) > 200 then raise exception 'Please keep it to 200 letters; add more in the details.' using errcode = '22023'; end if;
  if length(coalesce(v_detail, '')) > 2000 then raise exception 'The details are too long (2,000 letters at most).' using errcode = '22023'; end if;
  if v_on > current_date then raise exception 'A milestone is something already done; the date cannot be in the future.' using errcode = '22023'; end if;
  if v_dim is not null and not exists (select 1 from mirror.dimensions d where d.key = v_dim) then raise exception 'Unknown area of life.' using errcode = '22023'; end if;

  if p_id is null then v_id := mirror.target_individual(p_individual);
  else
    select * into m from mirror.milestones where id = p_id;
    if not found or (p_individual is not null and p_individual <> m.individual_id) then raise exception 'That milestone is not available.' using errcode = 'P0002'; end if;
    v_id := m.individual_id;
    perform mirror.require(v_id, m.category, 'edit', null, 'milestones', m.id::text);
  end if;
  if v_goal is not null then
    select g.dimension_key into v_dim from mirror.goals g where g.id = v_goal and g.individual_id = v_id;
    if not found then raise exception 'That goal is not available.' using errcode = 'P0002'; end if;
  end if;
  v_cat := mirror.dimension_category(v_dim);
  gate := mirror.require(v_id, v_cat, 'edit', null, 'milestones', p_id::text);

  if p_id is null then
    insert into mirror.milestones (individual_id, goal_id, dimension_key, category, title, detail, achieved_on, added_by, added_by_role)
    values (v_id, v_goal, v_dim, v_cat, v_title, v_detail, v_on, lower(auth.email()), gate ->> 'role')
    returning * into m;
  else
    -- changing the words or date of a confirmed milestone takes the confirmation off
    update mirror.milestones set goal_id = v_goal, dimension_key = v_dim, category = v_cat, title = v_title, detail = v_detail, achieved_on = v_on,
        verified_at = case when (m.title, m.achieved_on) is distinct from (v_title, v_on) then null else m.verified_at end,
        verified_by = case when (m.title, m.achieved_on) is distinct from (v_title, v_on) then null else m.verified_by end
     where id = m.id returning * into m;
  end if;
  return mirror.milestone_json(m);
end $$;

-- an organization the person works with confirms a milestone (same rule as verifying a need, D-27); p_confirm false takes it back
create or replace function public.mirror_milestone_confirm(p_id uuid, p_confirm boolean default true) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare m mirror.milestones; gate jsonb;
begin
  select * into m from mirror.milestones where id = p_id;
  if not found then raise exception 'That milestone is not available.' using errcode = 'P0002'; end if;
  gate := mirror.require(m.individual_id, m.category, 'edit', null, 'milestones', m.id::text);
  if p_confirm and (gate ->> 'role') not in ('coordinator', 'org_admin') then
    raise exception 'A milestone is confirmed by someone from an organization you work with.' using errcode = '42501';
  end if;
  update mirror.milestones set verified_at = case when p_confirm then now() end, verified_by = case when p_confirm then lower(auth.email()) end
   where id = m.id returning * into m;
  return mirror.milestone_json(m);
end $$;

-- ---------------------------------------------------------------- removing: the person only
create or replace function public.mirror_plan_delete(p_kind text, p_id uuid) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare v_ind uuid; v_cat text; gate jsonb;
begin
  if p_kind = 'goal' then select individual_id, category into v_ind, v_cat from mirror.goals where id = p_id;
  elsif p_kind = 'action' then select individual_id, category into v_ind, v_cat from mirror.action_items where id = p_id;
  elsif p_kind = 'milestone' then select individual_id, category into v_ind, v_cat from mirror.milestones where id = p_id;
  else raise exception 'Unknown kind.' using errcode = '22023'; end if;
  if v_ind is null then raise exception 'That is not available.' using errcode = 'P0002'; end if;
  gate := mirror.require(v_ind, v_cat, 'edit', null, case p_kind when 'goal' then 'goals' when 'action' then 'action_items' else 'milestones' end, p_id::text);
  if (gate ->> 'role') <> 'self' then
    raise exception 'Only the person removes things from their plan. You can mark a goal "let go" or a step "not doing".' using errcode = '42501';
  end if;
  if p_kind = 'goal' then delete from mirror.goals where id = p_id;            -- its steps go with it; its milestones stay, unlinked
  elsif p_kind = 'action' then delete from mirror.action_items where id = p_id;
  else delete from mirror.milestones where id = p_id; end if;
  return true;
end $$;

-- ---------------------------------------------------------------- the person's own download
create or replace function public.mirror_my_export_plan() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return jsonb_build_object(
    'goals', coalesce((select jsonb_agg(jsonb_build_object('goal', g.title, 'area', d.title, 'details', g.detail, 'stage', g.stage, 'hope_by', g.hope_by,
        'status', g.status, 'achieved_on', g.achieved_on, 'set_by', g.set_by_role, 'added', g.created_at) order by g.created_at)
      from mirror.goals g join mirror.dimensions d on d.key = g.dimension_key where g.individual_id = v), '[]'::jsonb),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('step', a.title, 'for_goal', (select g.title from mirror.goals g where g.id = a.goal_id),
        'for_need', (select n.title from mirror.needs n where n.id = a.need_id), 'who', case when a.who = 'me' then 'me' else a.helper end,
        'due_on', a.due_on, 'status', a.status, 'done_at', a.done_at, 'added_by', a.added_by_role) order by a.created_at)
      from mirror.action_items a where a.individual_id = v), '[]'::jsonb),
    'milestones', coalesce((select jsonb_agg(jsonb_build_object('milestone', m.title, 'details', m.detail, 'achieved_on', m.achieved_on,
        'area', (select d.title from mirror.dimensions d where d.key = m.dimension_key), 'confirmed_at', m.verified_at, 'added_by', m.added_by_role)
        order by m.achieved_on)
      from mirror.milestones m where m.individual_id = v), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- row security and grants
alter table mirror.goals enable row level security;
alter table mirror.action_items enable row level security;
alter table mirror.milestones enable row level security;
revoke all on mirror.goals, mirror.action_items, mirror.milestones from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.goals, mirror.action_items, mirror.milestones to service_role;

revoke all on function mirror.action_items_same_person(), mirror.milestones_same_person(), mirror.plan_no_truncate(), mirror.plan_date(jsonb, text),
  mirror.goal_json(mirror.goals), mirror.action_json(mirror.action_items), mirror.milestone_json(mirror.milestones) from public, anon, authenticated;
grant execute on function mirror.plan_date(jsonb, text), mirror.goal_json(mirror.goals), mirror.action_json(mirror.action_items),
  mirror.milestone_json(mirror.milestones) to service_role;

revoke all on function public.mirror_plan(uuid), public.mirror_goal_save(uuid, jsonb, uuid), public.mirror_action_save(uuid, jsonb, uuid),
  public.mirror_milestone_save(uuid, jsonb, uuid), public.mirror_milestone_confirm(uuid, boolean), public.mirror_plan_delete(text, uuid),
  public.mirror_my_export_plan() from public, anon;
grant execute on function public.mirror_plan(uuid), public.mirror_goal_save(uuid, jsonb, uuid), public.mirror_action_save(uuid, jsonb, uuid),
  public.mirror_milestone_save(uuid, jsonb, uuid), public.mirror_milestone_confirm(uuid, boolean), public.mirror_plan_delete(text, uuid),
  public.mirror_my_export_plan() to authenticated, service_role;
