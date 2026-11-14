-- The Human Mirror T7.2: resource suggestions (Phase 7, step 5 of the handoff).
-- "resource_suggestions, statuses suggested / eligibility_confirmed / applied / enrolled; match on area, need, city/county, household;
--  the 'suggested' label is always visible." DATABASE_DESIGN: "Suggested is never shown as eligible (Part 11)."
--
-- Rules (defaults, recorded as D-32 for Stephen to confirm)
--   * Matches come from the person's OPEN needs (identified, planning, in progress) and the T7.1 links (mirror.resource_categories):
--     a program linked to the need's area of life is a match. Up to 3 per need; a program already shown for an earlier need is not
--     repeated. Organizations marked "do not refer" in CHPMS are never suggested. Programs already on the person's list are left out.
--   * City/county: the person may say where they live, in five plain choices (city of Milwaukee, elsewhere in Milwaukee County,
--     Waukesha/Ozaukee/Washington County, elsewhere in Wisconsin, outside Wisconsin). The directory's service area is free text, so
--     the filter is coarse and the program's own "Serves" text is always shown. No place given = nothing is filtered out.
--   * Household: a child who lives with the person (household_members) or a birth year 62+ years ago counts for "Families with children"
--     and "Seniors". The person may also tick which CHPMS groups they are in (veterans, returning citizens, disabilities ...).
--     A program written only for groups the person said they are not in is left out; matching groups rank first.
--     The place, the groups and the household groups are used only when the person looks: a coordinator's list is matched on needs
--     and areas only, so nothing private shows through what is left out or the order. Only the person sees or changes place and groups.
--   * Nothing is added by itself. "Save to my list" adds a suggestion with status "suggested". Statuses: suggested, eligibility
--     confirmed, applied, enrolled, not for me (declined). Only someone from an organization the person works with, with "see and
--     change" for that topic, may mark "eligibility confirmed" (same idea as D-27: someone other than the person confirmed it), with a
--     note saying how it was confirmed. Going back to "suggested" takes the confirmation off. The person and such a coordinator may set
--     the other statuses; every change is kept in resource_suggestion_events. Only the person removes one from the list (like D-30).
--   * A suggestion's privacy topic is its need's topic (or, without a need, its area's topic as for strengths). Coordinators see a
--     suggestion only when they may see that topic; nobody but the person gets a count of what is hidden (D-29 point 5).
--   * No availability is claimed: the directory's open/closed text is not shown (Part 11: never show unverified availability).
--     The page shows how to apply, the phone, the link and the date the directory last checked the program.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only, no TRUNCATE; authenticated and anon none.

-- ---------------------------------------------------------------- tables
create table mirror.resource_profiles (
  individual_id uuid primary key references mirror.individuals(id) on delete cascade,
  place text check (place is null or place in ('milwaukee_city', 'milwaukee_county', 'nearby_county', 'wisconsin', 'outside')),
  groups text[] not null default '{}',
  groups_answered boolean not null default false,       -- true once the person has saved the groups question (even with none ticked)
  updated_at timestamptz not null default now(),
  constraint resource_profiles_groups check (groups <@ array['At risk of eviction', 'Disabilities', 'Experiencing homelessness',
    'Families with children', 'Fixed income (SS/SSI/SSDI/VA)', 'Low-income working', 'No current income', 'Returning citizens',
    'Seniors', 'Veterans']::text[])
);
create trigger resource_profiles_touch before update on mirror.resource_profiles for each row execute function mirror.touch();

create table mirror.resource_suggestions (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  chpms_program_id text references public.chpms_programs(program_id) on delete set null,
  program_name text not null check (length(program_name) between 1 and 300),   -- kept if the directory drops the program
  org_name text check (org_name is null or length(org_name) <= 300),
  need_id uuid references mirror.needs(id) on delete set null,
  dimension_key text references mirror.dimensions(key) on delete restrict,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  status text not null default 'suggested' check (status in ('suggested', 'eligibility_confirmed', 'applied', 'enrolled', 'declined')),
  status_note text check (status_note is null or length(status_note) <= 1000),
  confirmed_by text,
  confirmed_by_role text,
  confirmed_at timestamptz,
  source text not null default 'match' check (source in ('match', 'coordinator')),
  source_note text check (source_note is null or length(source_note) <= 500),
  added_by text not null,
  added_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint resource_suggestions_confirmed check ((status = 'eligibility_confirmed') <= (confirmed_at is not null)),
  constraint resource_suggestions_not_eligible check (status <> 'suggested' or confirmed_at is null)
);
create unique index resource_suggestions_one on mirror.resource_suggestions (individual_id, chpms_program_id) where chpms_program_id is not null;
create index resource_suggestions_person on mirror.resource_suggestions (individual_id, status);
create trigger resource_suggestions_touch before update on mirror.resource_suggestions for each row execute function mirror.touch();

create table mirror.resource_suggestion_events (
  id bigint generated always as identity primary key,
  suggestion_id uuid not null references mirror.resource_suggestions(id) on delete cascade,
  from_status text,
  to_status text not null,
  note text check (note is null or length(note) <= 1000),
  by_email text not null,
  by_role text not null,
  at timestamptz not null default now()
);
create index resource_suggestion_events_s on mirror.resource_suggestion_events (suggestion_id, at);

create trigger resource_profiles_no_truncate before truncate on mirror.resource_profiles for each statement execute function mirror.resource_no_truncate();
create trigger resource_suggestions_no_truncate before truncate on mirror.resource_suggestions for each statement execute function mirror.resource_no_truncate();
create trigger resource_suggestion_events_no_truncate before truncate on mirror.resource_suggestion_events for each statement execute function mirror.resource_no_truncate();

alter table mirror.resource_profiles enable row level security;
alter table mirror.resource_suggestions enable row level security;
alter table mirror.resource_suggestion_events enable row level security;
revoke all on mirror.resource_profiles, mirror.resource_suggestions, mirror.resource_suggestion_events from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.resource_profiles, mirror.resource_suggestions, mirror.resource_suggestion_events to service_role;

-- ---------------------------------------------------------------- does a CHPMS service area (free text) reach a place?
-- Coarse on purpose; the page always shows the text itself. Empty text reaches everywhere.
create or replace function mirror.place_served(p_area text, p_place text) returns boolean
language sql immutable set search_path = mirror, public as $$
  select case
    when p_place is null or coalesce(btrim(p_area), '') = '' then true
    when p_area ~* 'national' then true
    when p_place = 'outside' then false
    when p_area ~* '(wisconsin|statewide|\mWI\M|WI/|54 WI)' and p_area !~* '(SE Wisconsin|state HOPWA outside)' then true
    when p_place = 'wisconsin' then p_area ~* 'state HOPWA outside'
    when p_place = 'nearby_county' then p_area ~* '(waukesha|ozaukee|washington|greater milwaukee|SE Wisconsin|metro)'
    when p_place = 'milwaukee_county' then
      p_area ~* '(county|greater milwaukee|SE Wisconsin|metro|milwaukee area|waukesha|West Allis|parish)'
      or (p_area ~* 'milwaukee' and p_area !~* '(city of milwaukee|MPS|milwaukee schools)')
    when p_place = 'milwaukee_city' then p_area ~* 'milwaukee' and p_area !~* 'excludes City of Milwaukee'
    else true end;
$$;

-- ---------------------------------------------------------------- privacy topic of a suggestion
create or replace function mirror.resource_category(p_need uuid, p_dimension text) returns text
language sql stable set search_path = mirror, public as $$
  select coalesce((select n.category from mirror.needs n where n.id = p_need), mirror.strength_category(p_dimension));
$$;

-- ---------------------------------------------------------------- groups that count for a person
-- p_self: the person's own ticked groups are used only when the person is the one looking.
create or replace function mirror.resource_groups(p_individual uuid, p_self boolean) returns text[]
language sql stable set search_path = mirror, public as $$
  select array(select distinct g from (
    select unnest(coalesce((select rp.groups from mirror.resource_profiles rp where rp.individual_id = p_individual), '{}')) g where p_self
    union all
    select 'Families with children' where p_self and exists (select 1 from mirror.household_members h
      where h.individual_id = p_individual and h.relationship = 'child' and h.lives_with)
    union all
    select 'Seniors' where p_self and exists (select 1 from mirror.individuals i
      where i.id = p_individual and i.birth_year is not null and extract(year from now())::int - i.birth_year >= 62)) x);
$$;

-- ---------------------------------------------------------------- one program as the page sees it (no availability claims)
create or replace function mirror.resource_program_json(p_program text) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('program_id', p.program_id, 'program_name', p.program_name, 'org_name', coalesce(nullif(o.dba, ''), o.legal_name),
    'serves', o.service_area, 'help', coalesce((select jsonb_agg(a.category order by a.category) from public.chpms_program_assist a
       where a.program_id = p.program_id and a.provided), '[]'::jsonb),
    'for', coalesce((select jsonb_agg(pp.population order by pp.population) from public.chpms_program_pops pp where pp.program_id = p.program_id), '[]'::jsonb),
    'who_qualifies', p.eligibility_summary, 'how_to_apply', p.how_to_apply, 'referral', p.referral_requirement,
    'phone', coalesce(nullif(p.intake_phone, ''), o.main_phone), 'link', coalesce(nullif(p.application_url, ''), o.website),
    'checked_on', coalesce(o.our_checked_on, p.date_accessed), 'areas', mirror.program_areas(p.program_id))
    from public.chpms_programs p join public.chpms_orgs o on o.org_id = p.org_id
   where p.program_id = p_program;
$$;

-- ---------------------------------------------------------------- matches (internal: no gate here; callers gate)
create or replace function mirror.resource_matches(p_individual uuid, p_self boolean) returns table (need_id uuid, program_id text, rank int)
language sql stable security definer set search_path = mirror, public as $$
  with prof as (
    select (select rp.place from mirror.resource_profiles rp where rp.individual_id = p_individual and p_self) place,
           coalesce((select rp.groups_answered from mirror.resource_profiles rp where rp.individual_id = p_individual and p_self), false) answered,
           mirror.resource_groups(p_individual, p_self) groups),
  open_needs as (
    select n.id, n.dimension_key, n.created_at,
           row_number() over (order by array_position(array['urgent', 'soon', 'later'], n.urgency), n.created_at) need_order
      from mirror.needs n
     where n.individual_id = p_individual and n.status in ('identified', 'planning', 'in_progress') and n.dimension_key is not null),
  cand as (
    select o.id need_id, o.need_order, p.program_id, p.program_name,
           (select count(*) from public.chpms_program_pops pp, prof where pp.program_id = p.program_id and pp.population = any (prof.groups))::int fit
      from open_needs o
      join mirror.resource_categories rc on rc.dimension_key = o.dimension_key
      join public.chpms_programs p on p.program_id = rc.chpms_program_id
      join public.chpms_orgs g on g.org_id = p.org_id
      cross join prof
     where coalesce(g.our_relationship, '') <> 'do_not_refer'
       and mirror.place_served(g.service_area, prof.place)
       and not exists (select 1 from mirror.resource_suggestions s where s.individual_id = p_individual and s.chpms_program_id = p.program_id)
       -- written only for groups this person is not in (they answered the question, or the household shows it): left out
       and not (prof.answered and exists (select 1 from public.chpms_program_pops pp where pp.program_id = p.program_id)
                and not exists (select 1 from public.chpms_program_pops pp where pp.program_id = p.program_id
                                 and (pp.population = any (prof.groups) or pp.population not in
                                      ('Veterans', 'Seniors', 'Returning citizens', 'Families with children', 'Disabilities'))))
     group by o.id, o.need_order, p.program_id, p.program_name),
  best as (   -- each program once, under the first need it fits
    select distinct on (c.program_id) c.* from cand c order by c.program_id, c.need_order),
  ranked as (
    select b.need_id, b.program_id,
           row_number() over (partition by b.need_id order by b.fit desc, lower(b.program_name)) rnk
      from best b)
  select r.need_id, r.program_id, r.rnk::int from ranked r where r.rnk <= 3;
$$;

-- ---------------------------------------------------------------- one saved suggestion as the page sees it
create or replace function mirror.resource_suggestion_json(s mirror.resource_suggestions) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', s.id, 'program_id', s.chpms_program_id, 'program_name', s.program_name, 'org_name', s.org_name,
    'program', case when s.chpms_program_id is not null then mirror.resource_program_json(s.chpms_program_id) end,
    'need_id', s.need_id, 'need_title', (select n.title from mirror.needs n where n.id = s.need_id),
    'dimension', s.dimension_key, 'dimension_title', (select d.title from mirror.dimensions d where d.key = s.dimension_key),
    'private', s.category <> 'general', 'status', s.status, 'status_note', s.status_note,
    'suggested_label', s.confirmed_at is null and s.status <> 'enrolled',
    'confirmed_by_role', s.confirmed_by_role, 'confirmed_at', s.confirmed_at, 'source', s.source, 'added_by_role', s.added_by_role,
    'created_at', s.created_at, 'updated_at', s.updated_at,
    'history', coalesce((select jsonb_agg(jsonb_build_object('from', e.from_status, 'to', e.to_status, 'note', e.note, 'by_role', e.by_role, 'at', e.at) order by e.at, e.id)
       from mirror.resource_suggestion_events e where e.suggestion_id = s.id), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------- the page: my list, matches per need, my place and groups
create or replace function public.mirror_resources(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_self boolean;
  v_ok text[] := '{}';
  c text;
  v_matches jsonb;
begin
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'view') then v_ok := v_ok || c; end if;
  end loop;
  if exists (select 1 from mirror.resource_suggestions s where s.individual_id = v_id) then
    perform mirror.allowed(v_id, 'general', 'view', null, 'resource_suggestions', null);
  end if;

  -- matches: only for needs the caller may see, and only when the caller may add (edit) in that need's topic
  select coalesce(jsonb_agg(jsonb_build_object('need_id', n.id, 'need_title', n.title, 'urgency', n.urgency,
      'dimension', n.dimension_key, 'dimension_title', (select d.title from mirror.dimensions d where d.key = n.dimension_key),
      'private', n.category <> 'general',
      'programs', coalesce((select jsonb_agg(mirror.resource_program_json(m.program_id) order by m.rank)
                              from mirror.resource_matches(v_id, v_self) m where m.need_id = n.id), '[]'::jsonb))
      order by array_position(array['urgent', 'soon', 'later'], n.urgency), n.created_at), '[]'::jsonb)
    into v_matches
    from mirror.needs n
   where n.individual_id = v_id and n.status in ('identified', 'planning', 'in_progress') and n.dimension_key is not null
     and n.category = any (v_ok) and mirror.may(v_id, n.category, 'edit');

  return jsonb_build_object(
    'self', v_self,
    'profile', case when v_self then coalesce((select jsonb_build_object('place', rp.place, 'groups', to_jsonb(rp.groups), 'groups_answered', rp.groups_answered)
                 from mirror.resource_profiles rp where rp.individual_id = v_id), jsonb_build_object('place', null, 'groups', '[]'::jsonb, 'groups_answered', false)) end,
    'household_groups', case when v_self then to_jsonb(array(select x from unnest(mirror.resource_groups(v_id, true)) x
                          where x not in (select unnest(coalesce((select rp.groups from mirror.resource_profiles rp where rp.individual_id = v_id), '{}'))))) end,
    'can_confirm', not v_self,
    'list', coalesce((select jsonb_agg(mirror.resource_suggestion_json(s) order by
              array_position(array['enrolled', 'eligibility_confirmed', 'applied', 'suggested', 'declined'], s.status), s.created_at)
       from mirror.resource_suggestions s where s.individual_id = v_id and s.category = any (v_ok)), '[]'::jsonb),
    'matches', v_matches);
end $$;

-- ---------------------------------------------------------------- save a matched (or chosen) program to the list
create or replace function public.mirror_resource_save(p_program text, p_need uuid default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  n mirror.needs;
  p record;
  v_dim text;
  v_cat text;
  g jsonb;
  s mirror.resource_suggestions;
begin
  select pr.program_id, pr.program_name, coalesce(nullif(o.dba, ''), o.legal_name) org_name, o.our_relationship
    into p from public.chpms_programs pr join public.chpms_orgs o on o.org_id = pr.org_id where pr.program_id = p_program;
  if not found then raise exception 'That program is not in the directory.' using errcode = 'P0002'; end if;
  if coalesce(p.our_relationship, '') = 'do_not_refer' then
    raise exception 'That program cannot be suggested.' using errcode = '42501';
  end if;
  if p_need is not null then
    select * into n from mirror.needs where id = p_need and individual_id = v_id;
    if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
    v_dim := n.dimension_key;
  else
    select rc.dimension_key into v_dim from mirror.resource_categories rc join mirror.dimensions d on d.key = rc.dimension_key
     where rc.chpms_program_id = p_program order by d.n limit 1;
  end if;
  v_cat := mirror.resource_category(p_need, v_dim);
  g := mirror.require(v_id, v_cat, 'edit', null, 'resource_suggestions', null);
  if exists (select 1 from mirror.resource_suggestions x where x.individual_id = v_id and x.chpms_program_id = p_program) then
    raise exception 'That program is already on the list.' using errcode = '23505';
  end if;
  insert into mirror.resource_suggestions (individual_id, chpms_program_id, program_name, org_name, need_id, dimension_key, category,
    source, added_by, added_by_role)
  values (v_id, p.program_id, p.program_name, p.org_name, p_need, v_dim, v_cat,
    case when g ->> 'role' = 'self' then 'match' else 'coordinator' end, lower(auth.email()), g ->> 'role')
  returning * into s;
  insert into mirror.resource_suggestion_events (suggestion_id, from_status, to_status, by_email, by_role)
  values (s.id, null, 'suggested', lower(auth.email()), g ->> 'role');
  return mirror.resource_suggestion_json(s);
end $$;

-- ---------------------------------------------------------------- change the status
create or replace function public.mirror_resource_status(p_id uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  s mirror.resource_suggestions;
  g jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_from text;
begin
  if coalesce(p_status, '') not in ('suggested', 'eligibility_confirmed', 'applied', 'enrolled', 'declined') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) > 1000 then raise exception 'The note is too long (1,000 letters at most).' using errcode = '22023'; end if;
  select * into s from mirror.resource_suggestions where id = p_id;
  if not found then raise exception 'That suggestion is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(s.individual_id, s.category, 'edit', null, 'resource_suggestions', s.id::text);
  if p_status = s.status then return mirror.resource_suggestion_json(s); end if;
  v_from := s.status;
  if p_status = 'eligibility_confirmed' then
    if (g ->> 'role') = 'self' then
      raise exception 'Eligibility is confirmed by someone from an organization you work with, after they check with the program. You can mark it applied or enrolled.' using errcode = '42501';
    end if;
    if v_note is null then raise exception 'Say how eligibility was confirmed (for example "called the program on 11/20").' using errcode = '22023'; end if;
    update mirror.resource_suggestions set status = p_status, status_note = v_note,
      confirmed_by = lower(auth.email()), confirmed_by_role = g ->> 'role', confirmed_at = now()
     where id = s.id returning * into s;
  elsif p_status = 'suggested' then
    update mirror.resource_suggestions set status = p_status, status_note = v_note, confirmed_by = null, confirmed_by_role = null, confirmed_at = null
     where id = s.id returning * into s;
  else
    update mirror.resource_suggestions set status = p_status, status_note = v_note where id = s.id returning * into s;
  end if;
  insert into mirror.resource_suggestion_events (suggestion_id, from_status, to_status, note, by_email, by_role)
  values (s.id, v_from, p_status, v_note, lower(auth.email()), g ->> 'role');
  return mirror.resource_suggestion_json(s);
end $$;

-- ---------------------------------------------------------------- remove one from the list (the person only)
create or replace function public.mirror_resource_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare s mirror.resource_suggestions; g jsonb;
begin
  select * into s from mirror.resource_suggestions where id = p_id;
  if not found then raise exception 'That suggestion is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(s.individual_id, s.category, 'edit', null, 'resource_suggestions', s.id::text);
  if (g ->> 'role') <> 'self' then
    raise exception 'Only the person removes a program from their list. You can mark it "not for me".' using errcode = '42501';
  end if;
  delete from mirror.resource_suggestions where id = s.id;
  return true;
end $$;

-- ---------------------------------------------------------------- the person's place and groups (the person only)
create or replace function public.mirror_resource_profile_save(p_place text, p_groups text[] default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.me();
  g jsonb;
  v_place text := nullif(btrim(coalesce(p_place, '')), '');
  v_groups text[] := coalesce((select array_agg(distinct x order by x) from unnest(coalesce(p_groups, '{}')) x where btrim(x) <> ''), '{}');
begin
  if v_id is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  g := mirror.require(v_id, 'general', 'edit', null, 'resource_profiles', null);
  if (g ->> 'role') <> 'self' then raise exception 'Only the person sets this.' using errcode = '42501'; end if;
  if v_place is not null and v_place not in ('milwaukee_city', 'milwaukee_county', 'nearby_county', 'wisconsin', 'outside') then
    raise exception 'Choose one of the places on the list.' using errcode = '22023';
  end if;
  if not (v_groups <@ array['At risk of eviction', 'Disabilities', 'Experiencing homelessness', 'Families with children',
      'Fixed income (SS/SSI/SSDI/VA)', 'Low-income working', 'No current income', 'Returning citizens', 'Seniors', 'Veterans']::text[]) then
    raise exception 'Choose groups from the list.' using errcode = '22023';
  end if;
  insert into mirror.resource_profiles (individual_id, place, groups, groups_answered)
  values (v_id, v_place, v_groups, p_groups is not null)
  on conflict (individual_id) do update set place = excluded.place,
    groups = case when p_groups is null then mirror.resource_profiles.groups else excluded.groups end,
    groups_answered = mirror.resource_profiles.groups_answered or excluded.groups_answered;
  return (select jsonb_build_object('place', rp.place, 'groups', to_jsonb(rp.groups), 'groups_answered', rp.groups_answered)
            from mirror.resource_profiles rp where rp.individual_id = v_id);
end $$;

-- ---------------------------------------------------------------- the person's own download
create or replace function public.mirror_my_export_resources() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.require(v, 'general', 'view', null, 'resource_suggestions', null);
  return jsonb_build_object(
    'where_and_groups', (select jsonb_build_object('place', rp.place, 'groups', to_jsonb(rp.groups), 'changed', rp.updated_at)
                           from mirror.resource_profiles rp where rp.individual_id = v),
    'programs', coalesce((select jsonb_agg(jsonb_build_object('program', s.program_name, 'organization', s.org_name,
        'for_need', (select n.title from mirror.needs n where n.id = s.need_id),
        'area', (select d.title from mirror.dimensions d where d.key = s.dimension_key),
        'status', s.status, 'note', s.status_note, 'eligibility_confirmed_by', s.confirmed_by_role, 'eligibility_confirmed_at', s.confirmed_at,
        'added_by', s.added_by_role, 'added', s.created_at,
        'history', coalesce((select jsonb_agg(jsonb_build_object('from', e.from_status, 'to', e.to_status, 'note', e.note, 'by', e.by_role, 'at', e.at) order by e.at, e.id)
           from mirror.resource_suggestion_events e where e.suggestion_id = s.id), '[]'::jsonb)) order by s.created_at)
      from mirror.resource_suggestions s where s.individual_id = v), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function mirror.place_served(text, text), mirror.resource_category(uuid, text), mirror.resource_groups(uuid, boolean),
  mirror.resource_program_json(text), mirror.resource_matches(uuid, boolean), mirror.resource_suggestion_json(mirror.resource_suggestions)
  from public, anon, authenticated;
grant execute on function mirror.place_served(text, text), mirror.resource_category(uuid, text), mirror.resource_groups(uuid, boolean),
  mirror.resource_program_json(text), mirror.resource_matches(uuid, boolean), mirror.resource_suggestion_json(mirror.resource_suggestions)
  to service_role;

revoke all on function public.mirror_resources(uuid), public.mirror_resource_save(text, uuid, uuid), public.mirror_resource_status(uuid, text, text),
  public.mirror_resource_delete(uuid), public.mirror_resource_profile_save(text, text[]), public.mirror_my_export_resources() from public, anon;
grant execute on function public.mirror_resources(uuid), public.mirror_resource_save(text, uuid, uuid), public.mirror_resource_status(uuid, text, text),
  public.mirror_resource_delete(uuid), public.mirror_resource_profile_save(text, text[]), public.mirror_my_export_resources() to authenticated, service_role;
