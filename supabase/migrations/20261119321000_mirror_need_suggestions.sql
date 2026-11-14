-- The Human Mirror T6.1, part 2 (Stephen 11/13/2026, D-27 option chosen: "suggest, with one tap"): needs suggested from the
-- person's own answers. Nothing is created until the person taps "Add as a need"; "Not now" hides a suggestion.
--
-- Where suggestions come from (current answers only):
--   1. any question answered "I'd like help with this"            key q:<set>:<question>   title = their help note, else "Help with: <question>"
--   2. a life area's "Would you like help with this part of your life?" = Yes, now (urgency soon) or Maybe later (urgency later)
--                                                                   key area:<area>          title = "Help with: <area title>"
--   3. the Needs reflection's "Which parts of life would you like help with?" (each area chosen)   key area:<area>
-- Area of life: the question's own area; for a private question (health, how you feel, legal, money, safety) ALWAYS the one area
-- of that topic, so a private answer can never become a need that organizations see as an everyday one. Everyday questions in
-- the reflections have no area: the person picks one when adding.
-- Person only (mirror.me(): never an organization, never View as). A need made from a suggestion remembers its key (needs.from_key),
-- so the suggestion does not come back; "Not now" is kept in mirror.need_suggestion_dismissals.
-- New table carries explicit grants (CLAUDE.md 10/30/2026 rule): service_role only, no TRUNCATE.

alter table mirror.needs add column from_key text check (from_key is null or length(from_key) <= 200);

create table mirror.need_suggestion_dismissals (
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  from_key text not null check (length(from_key) <= 200),
  at timestamptz not null default now(),
  primary key (individual_id, from_key)
);
alter table mirror.need_suggestion_dismissals enable row level security;
revoke all on mirror.need_suggestion_dismissals from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.need_suggestion_dismissals to service_role;

-- the one area of life for a private topic (null for everyday)
create or replace function mirror.category_dimension(p_category text) returns text
language sql immutable set search_path = mirror, public as $$
  select case p_category when 'health' then 'physical_health' when 'mental_health' then 'mental_health' when 'legal' then 'identity_legal'
    when 'financial' then 'finances' when 'safety' then 'safety' end;
$$;

-- every open suggestion for one person (no permission check here: callers pass mirror.me())
create or replace function mirror.need_suggestions_for(v uuid) returns table (from_key text, title text, dimension_key text, urgency text, source text)
language sql stable set search_path = mirror, public as $$
  with s as (
    -- 1. "I'd like help with this"
    select 'q:' || ca.set_key || ':' || ca.question_key as from_key,
      left(coalesce(nullif(btrim(ca.note), ''), 'Help with: ' || q.prompt), 200) as title,
      case when ca.category = 'general' then qs.dimension_key else mirror.category_dimension(ca.category) end as dimension_key,
      'soon' as urgency, q.prompt as source, 1 as kind, ca.answered_at as at
    from mirror.current_answers ca
    join mirror.question_sets qs on qs.key = ca.set_key
    join mirror.reflection_questions q on q.set_id = qs.id and q.key = ca.question_key
    where ca.individual_id = v and ca.state = 'needs_help'
    union all
    -- 2. a life area: "Would you like help with this part of your life?"
    select 'area:' || qs.dimension_key, 'Help with: ' || d.title, qs.dimension_key,
      case when ca.value #>> '{}' = 'now' then 'soon' else 'later' end, q.prompt, 2, ca.answered_at
    from mirror.current_answers ca
    join mirror.question_sets qs on qs.key = ca.set_key and qs.kind = 'dimension'
    join mirror.dimensions d on d.key = qs.dimension_key
    join mirror.reflection_questions q on q.set_id = qs.id and q.key = ca.question_key
    where ca.individual_id = v and ca.question_key = 'help_wanted' and ca.state = 'answered' and ca.value #>> '{}' in ('now', 'later')
    union all
    -- 3. the Needs reflection: "Which parts of life would you like help with?"
    select 'area:' || d.key, 'Help with: ' || d.title, d.key, 'soon', q.prompt, 3, ca.answered_at
    from mirror.current_answers ca
    join mirror.question_sets qs on qs.key = ca.set_key
    join mirror.reflection_questions q on q.set_id = qs.id and q.key = ca.question_key
    cross join lateral jsonb_array_elements_text(ca.value) as pick(area)
    join mirror.dimensions d on d.key = pick.area
    where ca.individual_id = v and ca.set_key = 'reflection_needs' and ca.question_key = 'help_areas' and ca.state = 'answered'
      and jsonb_typeof(ca.value) = 'array'
  )
  -- one suggestion per key (an area named in both places: the life area's own answer wins), minus those already added or set aside
  select distinct on (s.from_key) s.from_key, s.title, s.dimension_key, s.urgency, s.source
  from s
  where not exists (select 1 from mirror.needs n where n.individual_id = v and n.from_key = s.from_key)
    and not exists (select 1 from mirror.need_suggestion_dismissals x where x.individual_id = v and x.from_key = s.from_key)
  order by s.from_key, s.kind, s.at desc;
$$;

create or replace function public.mirror_need_suggestions() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('key', x.from_key, 'title', x.title, 'dimension', x.dimension_key,
      'dimension_title', d.title, 'urgency', x.urgency, 'private', mirror.dimension_category(x.dimension_key) <> 'general', 'source', x.source)
      order by (x.urgency <> 'soon'), d.n nulls last, x.title)
    from mirror.need_suggestions_for(v) x left join mirror.dimensions d on d.key = x.dimension_key), '[]'::jsonb);
end $$;

-- "Add as a need": made from the suggestion as it stands now; p_dimension only when the suggestion has no area of its own
create or replace function public.mirror_need_add_suggested(p_key text, p_dimension text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.me();
  x record;
  v_dim text;
  n mirror.needs;
begin
  select * into x from mirror.need_suggestions_for(v) s where s.from_key = p_key;
  if not found then raise exception 'That suggestion is no longer there.' using errcode = 'P0002'; end if;
  v_dim := coalesce(x.dimension_key, p_dimension);
  if v_dim is null or not exists (select 1 from mirror.dimensions d where d.key = v_dim) then
    raise exception 'Choose an area of life for this need.' using errcode = '22023';
  end if;
  insert into mirror.needs (individual_id, dimension_key, category, title, urgency, identified_by, identified_by_role, from_key)
  values (v, v_dim, mirror.dimension_category(v_dim), x.title, x.urgency, lower(auth.email()), 'self', p_key)
  returning * into n;
  insert into mirror.need_events (need_id, by_email, by_role, from_status, to_status, note)
  values (n.id, lower(auth.email()), 'self', null, 'identified', 'Added from your answers');
  return mirror.need_json(n);
end $$;

-- "Not now"
create or replace function public.mirror_need_suggestion_dismiss(p_key text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if coalesce(length(p_key), 0) not between 1 and 200 then raise exception 'Unknown suggestion.' using errcode = '22023'; end if;
  insert into mirror.need_suggestion_dismissals (individual_id, from_key) values (v, p_key) on conflict do nothing;
end $$;

-- the person's download also says which needs came from their answers
create or replace function public.mirror_my_export_needs() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('area', d.title, 'need', n.title, 'details', n.detail, 'urgency', n.urgency,
      'status', n.status, 'added', n.created_at, 'from_your_answers', n.from_key is not null, 'verified_at', n.verified_at,
      'history', (select jsonb_agg(jsonb_build_object('at', e.at, 'by', e.by_role, 'from', e.from_status, 'to', e.to_status, 'note', e.note)
                  order by e.at, e.id) from mirror.need_events e where e.need_id = n.id))
      order by n.created_at, n.title, n.id)
    from mirror.needs n join mirror.dimensions d on d.key = n.dimension_key where n.individual_id = v), '[]'::jsonb);
end $$;

revoke all on function mirror.category_dimension(text), mirror.need_suggestions_for(uuid) from public, anon, authenticated;
grant execute on function mirror.category_dimension(text), mirror.need_suggestions_for(uuid) to service_role;
revoke all on function public.mirror_need_suggestions(), public.mirror_need_add_suggested(text, text),
  public.mirror_need_suggestion_dismiss(text) from public, anon;
grant execute on function public.mirror_need_suggestions(), public.mirror_need_add_suggested(text, text),
  public.mirror_need_suggestion_dismiss(text) to authenticated, service_role;
