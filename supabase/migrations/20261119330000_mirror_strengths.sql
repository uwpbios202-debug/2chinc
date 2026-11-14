-- The Human Mirror T6.2: strengths inventory (Stephen 11/13/2026 "go for T6.2 now"; the prompt's Phase 6 card:
-- "A list beside the needs: skills, talents, experience, credentials, languages, interests and relationships.
--  It builds on the 'What do I have within me?' reflection.").
--
-- Rules
--   * A strength is one short line (title) with optional details, of one kind: skill, talent, experience, credential, language,
--     interest or relationship. It may be tied to one area of life (mirror.dimensions); its privacy topic comes from that area the
--     same way the life-area questions do (D-14): physical health -> health, how you feel inside -> mental_health, ID and legal -> legal,
--     money -> financial, safety -> safety, anything else (or no area) -> general. Organizations see a strength only when they may see its topic.
--   * The person (or a coordinator with "see and change" for that topic) adds, edits and removes strengths. Unlike needs, a strength
--     is simply the person's own list, so it can be removed; the gate logs who did it.
--   * Suggestions come from answers the person already gave (the "What do I have within me?" reflection, "Where I come from" and
--     "Giving back"). Nothing is added by itself: a suggestion becomes a strength only when someone with edit access saves it,
--     and "Not a strength" hides that one suggestion for good (strength_dismissals).
--   * Every read and write passes mirror.allowed (the one gate).
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only, no TRUNCATE; authenticated and anon none.

-- ---------------------------------------------------------------- tables
create table mirror.strengths (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  kind text not null check (kind in ('skill', 'talent', 'experience', 'credential', 'language', 'interest', 'relationship')),
  title text not null check (length(btrim(title)) between 1 and 120),
  detail text check (detail is null or length(detail) <= 1000),
  dimension_key text references mirror.dimensions(key) on delete restrict,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  source text not null default 'self' check (source in ('self', 'coordinator')),
  source_key text check (source_key is null or length(source_key) <= 200),   -- set when it came from a suggestion
  added_by text not null,
  added_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index strengths_person on mirror.strengths (individual_id, kind);
create unique index strengths_source on mirror.strengths (individual_id, source_key) where source_key is not null;
create trigger strengths_touch before update on mirror.strengths for each row execute function mirror.touch();

create table mirror.strength_dismissals (
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  source_key text not null check (length(source_key) <= 200),
  by_email text not null,
  at timestamptz not null default now(),
  primary key (individual_id, source_key)
);

create or replace function mirror.strengths_no_truncate() returns trigger language plpgsql set search_path = mirror as $$
begin
  raise exception 'Strengths are never emptied in bulk.' using errcode = '42501';
end $$;
create trigger strengths_no_truncate before truncate on mirror.strengths for each statement execute function mirror.strengths_no_truncate();
create trigger strength_dismissals_no_truncate before truncate on mirror.strength_dismissals for each statement execute function mirror.strengths_no_truncate();

-- ---------------------------------------------------------------- privacy topic of a strength (no area = everyday)
create or replace function mirror.strength_category(p_dimension text) returns text
language sql immutable set search_path = mirror, public as $$
  select case p_dimension
    when 'physical_health' then 'health'
    when 'mental_health' then 'mental_health'
    when 'identity_legal' then 'legal'
    when 'finances' then 'financial'
    when 'safety' then 'safety'
    else 'general' end;
$$;

-- ---------------------------------------------------------------- one strength as the page sees it
create or replace function mirror.strength_json(s mirror.strengths) returns jsonb
language sql stable set search_path = mirror, public as $$
  select jsonb_build_object('id', s.id, 'kind', s.kind, 'title', s.title, 'detail', s.detail,
    'dimension', s.dimension_key, 'dimension_title', (select d.title from mirror.dimensions d where d.key = s.dimension_key),
    'category', s.category, 'private', s.category <> 'general', 'source', s.source, 'from_answers', s.source_key is not null,
    'added_by_role', s.added_by_role, 'created_at', s.created_at, 'updated_at', s.updated_at);
$$;

-- ---------------------------------------------------------------- suggestions from answers (internal: no gate here)
-- Which answers feed which kind. A long answer is split at line breaks, semicolons and commas into short pieces.
create or replace function mirror.strength_candidates(p_individual uuid) returns table (source_key text, kind text, title text, detail text,
  set_key text, question_key text, category text, question text)
language sql stable set search_path = mirror, public as $$
  with src(set_key, question_key, kind) as (values
    ('reflection_assets', 'can_do', 'skill'), ('reflection_assets', 'languages', 'language'),
    ('reflection_assets', 'good_at', 'talent'), ('reflection_assets', 'appreciate', 'talent'), ('reflection_assets', 'strengths', 'talent'),
    ('reflection_assets', 'more_skills', 'skill'), ('reflection_assets', 'teach', 'skill'),
    ('reflection_assets', 'know', 'experience'), ('reflection_assets', 'experience_to_skill', 'experience'),
    ('reflection_assets', 'interests', 'interest'),
    ('reflection_history', 'accomplished', 'experience'), ('reflection_history', 'talents', 'talent'),
    ('reflection_history', 'schooling', 'credential'), ('reflection_history', 'people', 'relationship'),
    ('reflection_contribution', 'already', 'experience'), ('reflection_contribution', 'share', 'skill'),
    ('reflection_contribution', 'teach', 'skill')),
  ans as (
    select src.kind, a.set_key, a.question_key, a.category, a.value, q.answer_type, q.options, q.prompt
      from src
      join mirror.current_answers a on a.set_key = src.set_key and a.question_key = src.question_key
      join mirror.question_sets qs on qs.key = a.set_key
      join mirror.reflection_questions q on q.set_id = qs.id and q.key = a.question_key
     where a.individual_id = p_individual and a.state = 'answered'),
  pieces as (
    -- choices: one per chosen option, by its label ("Speaking more than one language" is left to the languages answer)
    select ans.*, o ->> 'label' as piece
      from ans cross join lateral jsonb_array_elements(case when jsonb_typeof(ans.value) = 'array' then ans.value else '[]'::jsonb end) v
      join lateral jsonb_array_elements(ans.options) o on o ->> 'value' = v #>> '{}'
     where ans.answer_type = 'multi' and v #>> '{}' <> 'languages'
    union all
    -- schooling: only finished schooling is a credential
    select ans.*, o ->> 'label'
      from ans join lateral jsonb_array_elements(ans.options) o on o ->> 'value' = ans.value #>> '{}'
     where ans.answer_type = 'choice' and ans.value #>> '{}' in ('high_school', 'certificate', 'degree')
    union all
    -- written answers: split into short pieces (languages also split at "and" and slashes)
    select ans.*, btrim(p)
      from ans cross join lateral regexp_split_to_table(ans.value #>> '{}',
             case when ans.question_key = 'languages' then '\s*(?:[\n;,/]|\s+and\s+)\s*' else '\s*[\n;,]\s*' end) p
     where ans.answer_type in ('text', 'long_text') and jsonb_typeof(ans.value) = 'string')
  select distinct on (k.source_key) k.source_key, k.kind,
         case when length(k.piece) > 120 then left(k.piece, 117) || '...' else k.piece end,
         case when length(k.piece) > 120 then left(k.piece, 1000) end,
         k.set_key, k.question_key, k.category, k.prompt
    from (select pieces.*, pieces.set_key || ':' || pieces.question_key || ':' || md5(lower(btrim(regexp_replace(pieces.piece, '[.!]+$', '')))) as source_key
            from pieces) k
   where length(btrim(regexp_replace(k.piece, '[.!]+$', ''))) >= 2
   order by k.source_key;
$$;

-- ---------------------------------------------------------------- list
create or replace function public.mirror_strengths(p_individual uuid default null) returns jsonb
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
  for c in select distinct s.category from mirror.strengths s where s.individual_id = v_id loop
    if mirror.may(v_id, c, 'view') then
      v_ok := v_ok || c;
      perform mirror.allowed(v_id, c, 'view', null, 'strengths', null);
    end if;
  end loop;
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'edit') then v_add := v_add || c; end if;
  end loop;
  return jsonb_build_object(
    'self', (r ->> 'role') = 'self',
    'can_add', to_jsonb(v_add),
    'strengths', coalesce((select jsonb_agg(mirror.strength_json(s) order by
        array_position(array['skill', 'talent', 'experience', 'credential', 'language', 'interest', 'relationship'], s.kind), lower(s.title))
      from mirror.strengths s where s.individual_id = v_id and s.category = any (v_ok)), '[]'::jsonb),
    'hidden', (select count(*) from mirror.strengths s where s.individual_id = v_id and not (s.category = any (v_ok))));
end $$;

-- ---------------------------------------------------------------- suggestions the caller may act on
-- Only for someone who may add strengths (edit on everyday topics), and only from answers in topics the caller may see.
-- Already saved (same suggestion, or same title) and dismissed ones are left out.
create or replace function public.mirror_strength_suggestions(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_cats text[] := '{}';
  c text;
begin
  perform mirror.require(v_id, 'general', 'view', null, '_probe', null);
  if not mirror.may(v_id, 'general', 'edit') then return '[]'::jsonb; end if;
  for c in select distinct x.category from mirror.strength_candidates(v_id) x loop
    if mirror.may(v_id, c, 'view') then v_cats := v_cats || c; end if;
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('source_key', x.source_key, 'kind', x.kind, 'title', x.title, 'detail', x.detail,
      'question', x.question) order by array_position(array['skill', 'talent', 'experience', 'credential', 'language', 'interest', 'relationship'], x.kind), x.title)
    from mirror.strength_candidates(v_id) x
    where x.category = any (v_cats)
      and not exists (select 1 from mirror.strengths s where s.individual_id = v_id and (s.source_key = x.source_key or lower(s.title) = lower(x.title)))
      and not exists (select 1 from mirror.strength_dismissals d where d.individual_id = v_id and d.source_key = x.source_key)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- add or edit
create or replace function public.mirror_strength_save(p_id uuid, p_kind text, p_title text, p_detail text default null,
  p_dimension text default null, p_source_key text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid;
  s mirror.strengths;
  g jsonb;
  v_dim text := nullif(btrim(coalesce(p_dimension, '')), '');
  v_cat text;
  v_title text := btrim(coalesce(p_title, ''));
  v_detail text := nullif(btrim(coalesce(p_detail, '')), '');
  v_src text := nullif(btrim(coalesce(p_source_key, '')), '');
begin
  if coalesce(p_kind, '') not in ('skill', 'talent', 'experience', 'credential', 'language', 'interest', 'relationship') then
    raise exception 'Choose what kind of strength this is.' using errcode = '22023';
  end if;
  if length(v_title) = 0 then raise exception 'Say the strength in a few words.' using errcode = '22023'; end if;
  if length(v_title) > 120 then raise exception 'Please keep it to 120 letters; add more in the details.' using errcode = '22023'; end if;
  if length(coalesce(v_detail, '')) > 1000 then raise exception 'The details are too long (1,000 letters at most).' using errcode = '22023'; end if;
  if v_dim is not null and not exists (select 1 from mirror.dimensions d where d.key = v_dim) then
    raise exception 'Unknown area of life.' using errcode = '22023';
  end if;
  v_cat := mirror.strength_category(v_dim);

  if p_id is null then
    v_id := mirror.target_individual(p_individual);
    g := mirror.require(v_id, v_cat, 'edit', null, 'strengths', null);
    if v_src is not null and not exists (select 1 from mirror.strength_candidates(v_id) x where x.source_key = v_src) then
      raise exception 'That suggestion is no longer in the answers.' using errcode = '22023';
    end if;
    if v_src is not null and exists (select 1 from mirror.strengths x where x.individual_id = v_id and x.source_key = v_src) then
      raise exception 'That one is already on the list.' using errcode = '23505';
    end if;
    insert into mirror.strengths (individual_id, kind, title, detail, dimension_key, category, source, source_key, added_by, added_by_role)
    values (v_id, p_kind, v_title, v_detail, v_dim, v_cat, case when g ->> 'role' = 'self' then 'self' else 'coordinator' end,
            v_src, lower(auth.email()), g ->> 'role')
    returning * into s;
    return mirror.strength_json(s);
  end if;

  select * into s from mirror.strengths where id = p_id;
  if not found then raise exception 'That strength is not available.' using errcode = 'P0002'; end if;
  if p_individual is not null and p_individual <> s.individual_id then raise exception 'That strength is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(s.individual_id, s.category, 'edit', null, 'strengths', s.id::text);
  if v_cat <> s.category then perform mirror.require(s.individual_id, v_cat, 'edit', null, 'strengths', s.id::text); end if;
  if (s.kind, s.title, s.detail, s.dimension_key) is distinct from (p_kind, v_title, v_detail, v_dim) then
    update mirror.strengths set kind = p_kind, title = v_title, detail = v_detail, dimension_key = v_dim, category = v_cat
     where id = s.id returning * into s;
  end if;
  return mirror.strength_json(s);
end $$;

-- ---------------------------------------------------------------- remove one strength
create or replace function public.mirror_strength_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare s mirror.strengths;
begin
  select * into s from mirror.strengths where id = p_id;
  if not found then raise exception 'That strength is not available.' using errcode = 'P0002'; end if;
  perform mirror.require(s.individual_id, s.category, 'edit', null, 'strengths', s.id::text);
  delete from mirror.strengths where id = s.id;
  return true;
end $$;

-- ---------------------------------------------------------------- "not a strength": hide one suggestion for good
create or replace function public.mirror_strength_dismiss(p_source_key text, p_individual uuid default null) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare v_id uuid := mirror.target_individual(p_individual);
begin
  perform mirror.require(v_id, 'general', 'edit', null, 'strength_dismissals', null);
  if not exists (select 1 from mirror.strength_candidates(v_id) x where x.source_key = p_source_key) then
    raise exception 'That suggestion is no longer in the answers.' using errcode = '22023';
  end if;
  insert into mirror.strength_dismissals (individual_id, source_key, by_email) values (v_id, p_source_key, lower(auth.email()))
  on conflict do nothing;
  return true;
end $$;

-- ---------------------------------------------------------------- the person's own download of their strengths
create or replace function public.mirror_my_export_strengths() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('kind', s.kind, 'strength', s.title, 'details', s.detail,
      'area', (select d.title from mirror.dimensions d where d.key = s.dimension_key), 'added_by', s.added_by_role,
      'from_answers', s.source_key is not null, 'added', s.created_at, 'changed', s.updated_at) order by s.kind, s.created_at)
    from mirror.strengths s where s.individual_id = v), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- row security and grants
alter table mirror.strengths enable row level security;
alter table mirror.strength_dismissals enable row level security;
revoke all on mirror.strengths, mirror.strength_dismissals from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.strengths, mirror.strength_dismissals to service_role;

revoke all on function mirror.strength_category(text), mirror.strength_json(mirror.strengths), mirror.strength_candidates(uuid),
  mirror.strengths_no_truncate() from public, anon, authenticated;
grant execute on function mirror.strength_category(text), mirror.strength_json(mirror.strengths), mirror.strength_candidates(uuid) to service_role;

revoke all on function public.mirror_strengths(uuid), public.mirror_strength_suggestions(uuid),
  public.mirror_strength_save(uuid, text, text, text, text, text, uuid), public.mirror_strength_delete(uuid),
  public.mirror_strength_dismiss(text, uuid), public.mirror_my_export_strengths() from public, anon;
grant execute on function public.mirror_strengths(uuid), public.mirror_strength_suggestions(uuid),
  public.mirror_strength_save(uuid, text, text, text, text, text, uuid), public.mirror_strength_delete(uuid),
  public.mirror_strength_dismiss(text, uuid), public.mirror_my_export_strengths() to authenticated, service_role;
