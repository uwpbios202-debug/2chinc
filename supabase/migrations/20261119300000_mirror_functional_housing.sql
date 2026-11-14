-- The Human Mirror Phase 5: functional and housing assessment (MASTER_ROADMAP T5.1 + T5.2). Session range 20261119300000-309999.
-- T5.1  functional_assessments (one sitting: by the person, or by a helper with the person), adl_assessments and iadl_assessments
--       (level + the person's own preference beside each + note). The 11 other functional areas are question sets of kind
--       'functional' (seed: 20261119301000, generated from site/mirror/assets/functional-data.js).
-- T5.2  housing_options (seed: 20261119301000, from site/mirror/assets/living-options.js), housing_profiles (one per person),
--       housing_history (one row per place lived).
-- Rules (prompt Part 5): never a diagnosis, never a score, nothing recommends a setting by itself. "Professional review needed" is
-- set ONLY by a helper (organization member with edit consent), never by the person and never automatically; the person sees it.
-- Who sees what (D-14): everything functional is private health information (topic 'health'); housing is 'general', except the
-- parts that are health (care setting, hospital, accessibility needs, "fits my needs") or legal (jail, eviction, criminal record):
-- those are left out for anyone without that topic shared, and saving by such a helper keeps them as they were.
-- History: a sitting, once finished, is never changed (trigger); a new check-in starts a new sitting. Housing history keeps every place.
-- Grants (CLAUDE.md, 10/30/2026 rule): the 6 new tables are for service_role only, row security on, no grants to anon or authenticated;
-- pages reach them only through the public.mirror_* functions below (security definer, fixed search_path), executable by authenticated.

-- ---------------------------------------------------------------- T5.1 functional

create table mirror.functional_assessments (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  organization_id uuid references mirror.organizations(id) on delete set null,   -- null: the person on their own
  assessed_by text not null,                                                     -- sign-in email of whoever started it
  assessed_by_role text not null check (assessed_by_role in ('self', 'coordinator', 'org_admin', 'volunteer')),
  is_self_report boolean not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  professional_review_needed boolean not null default false,
  review_note text check (review_note is null or length(review_note) <= 1000),
  review_by_role text,
  review_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (is_self_report = (assessed_by_role = 'self'))
);
create index functional_assessments_person on mirror.functional_assessments (individual_id, started_at desc);
create unique index functional_assessments_one_open on mirror.functional_assessments (individual_id, is_self_report) where completed_at is null;

create table mirror.adl_assessments (
  id uuid primary key default gen_random_uuid(),
  functional_assessment_id uuid not null references mirror.functional_assessments(id) on delete cascade,
  activity text not null check (activity in ('bathing', 'dressing', 'transferring', 'eating', 'toileting', 'continence')),
  level text check (level in ('independent', 'with_device', 'some_help', 'full_help', 'not_assessed')),
  preference text check (preference in ('as_now', 'more_on_own', 'tools', 'some_help', 'more_help', 'not_sure')),
  note text check (note is null or length(note) <= 1000),
  answered_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (functional_assessment_id, activity),
  check (level is not null or preference is not null or note is not null)
);

create table mirror.iadl_assessments (
  id uuid primary key default gen_random_uuid(),
  functional_assessment_id uuid not null references mirror.functional_assessments(id) on delete cascade,
  activity text not null check (activity in ('meal_prep', 'shopping', 'medication', 'finances', 'transportation', 'housekeeping', 'laundry', 'devices')),
  level text check (level in ('independent', 'with_device', 'some_help', 'full_help', 'not_assessed')),
  preference text check (preference in ('as_now', 'more_on_own', 'tools', 'some_help', 'more_help', 'not_sure')),
  note text check (note is null or length(note) <= 1000),
  answered_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (functional_assessment_id, activity),
  check (level is not null or preference is not null or note is not null)
);

-- A finished sitting is history: its rows never change. Only the review mark may still be set on it (a helper's later note).
create or replace function mirror.functional_finished_frozen() returns trigger language plpgsql set search_path = mirror as $$
declare v_done timestamptz;
begin
  if tg_table_name = 'functional_assessments' then
    if tg_op = 'DELETE' then
      if old.completed_at is not null and exists (select 1 from mirror.individuals i where i.id = old.individual_id) then
        raise exception 'A finished check-in is kept as it was.' using errcode = '42501';
      end if;
      return old;
    end if;
    if old.completed_at is not null and (new.individual_id, new.organization_id, new.assessed_by, new.assessed_by_role, new.is_self_report,
        new.started_at, new.completed_at) is distinct from (old.individual_id, old.organization_id, old.assessed_by, old.assessed_by_role,
        old.is_self_report, old.started_at, old.completed_at) then
      raise exception 'A finished check-in is kept as it was.' using errcode = '42501';
    end if;
    return new;
  end if;
  select f.completed_at into v_done from mirror.functional_assessments f
    where f.id = case when tg_op = 'DELETE' then old.functional_assessment_id else new.functional_assessment_id end;
  if v_done is not null then raise exception 'A finished check-in is kept as it was. Start a new check-in to change an answer.' using errcode = '42501'; end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger functional_assessments_frozen before update or delete on mirror.functional_assessments
  for each row execute function mirror.functional_finished_frozen();
create trigger adl_assessments_frozen before insert or update or delete on mirror.adl_assessments
  for each row execute function mirror.functional_finished_frozen();
create trigger iadl_assessments_frozen before insert or update or delete on mirror.iadl_assessments
  for each row execute function mirror.functional_finished_frozen();

-- ---------------------------------------------------------------- T5.2 housing

create table mirror.housing_options (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (key in ('independent', 'supported_independent', 'assisted', 'skilled_nursing', 'accessible', 'permanent_supportive', 'other_specialized')),
  sort int not null,
  title text not null,
  summary text not null,
  description jsonb not null default '{}'::jsonb,   -- what, support, who, pay, ask[] (same text as living-options.js)
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function mirror.housing_arrangement_ok(p text) returns boolean language sql immutable set search_path = mirror as $$
  select p is null or p in ('own_home', 'renting', 'with_others', 'shelter', 'transitional', 'supportive', 'care_setting', 'hospital_treatment', 'jail', 'hotel', 'outside', 'other');
$$;
-- The topic an arrangement belongs to (who may see it).
create or replace function mirror.housing_arrangement_topic(p text) returns text language sql immutable set search_path = mirror as $$
  select case when p in ('care_setting', 'hospital_treatment') then 'health' when p = 'jail' then 'legal' else 'general' end;
$$;
-- The topic of a barrier key.
create or replace function mirror.housing_barrier_topic(p text) returns text language sql immutable set search_path = mirror as $$
  select case when p in ('eviction', 'criminal_record') then 'legal' when p = 'fit_needs' then 'health' else 'general' end;
$$;

create table mirror.housing_profiles (
  individual_id uuid primary key references mirror.individuals(id) on delete cascade,
  current_arrangement text check (mirror.housing_arrangement_ok(current_arrangement)),
  current_note text check (current_note is null or length(current_note) <= 2000),
  preferred_option_ids uuid[] not null default '{}',   -- options the person wants to learn about (checked against housing_options)
  barriers jsonb not null default '{"keys": [], "note": null}'::jsonb,
  accessibility_needs jsonb not null default '{"keys": [], "note": null}'::jsonb,   -- topic 'health'
  professional_review_needed boolean not null default false,
  review_note text check (review_note is null or length(review_note) <= 1000),
  review_by_role text,
  review_at timestamptz,
  updated_by_role text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(barriers -> 'keys') = 'array' and jsonb_typeof(accessibility_needs -> 'keys') = 'array')
);

create table mirror.housing_history (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  from_on date,
  to_on date,
  arrangement text not null check (mirror.housing_arrangement_ok(arrangement)),
  city text check (city is null or length(city) <= 120),
  note text check (note is null or length(note) <= 2000),
  sensitive_category text check (sensitive_category in ('health', 'mental_health', 'safety', 'legal')),   -- the person may mark a row private
  created_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (to_on is null or from_on is null or to_on >= from_on)
);
create index housing_history_person on mirror.housing_history (individual_id, from_on desc nulls last);

-- ---------------------------------------------------------------- helpers

-- One sitting as JSON (role only, never the helper's email).
create or replace function mirror.fa_json(p_id uuid) returns jsonb language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', f.id, 'started_at', f.started_at, 'completed_at', f.completed_at, 'by', f.assessed_by_role,
    'self_report', f.is_self_report, 'organization', (select o.name from mirror.organizations o where o.id = f.organization_id),
    'professional_review_needed', f.professional_review_needed, 'review_note', f.review_note, 'review_by', f.review_by_role, 'review_at', f.review_at,
    'adl', coalesce((select jsonb_object_agg(a.activity, jsonb_build_object('level', a.level, 'preference', a.preference, 'note', a.note, 'by', a.answered_by_role, 'at', a.updated_at))
      from mirror.adl_assessments a where a.functional_assessment_id = f.id), '{}'::jsonb),
    'iadl', coalesce((select jsonb_object_agg(a.activity, jsonb_build_object('level', a.level, 'preference', a.preference, 'note', a.note, 'by', a.answered_by_role, 'at', a.updated_at))
      from mirror.iadl_assessments a where a.functional_assessment_id = f.id), '{}'::jsonb))
  from mirror.functional_assessments f where f.id = p_id;
$$;

-- Keeps only the keys of a {keys, note} list that the caller may see.
create or replace function mirror.housing_keys_visible(p jsonb, p_ok text[]) returns jsonb language sql immutable set search_path = mirror as $$
  select coalesce((select jsonb_agg(k) from jsonb_array_elements_text(coalesce(p -> 'keys', '[]'::jsonb)) k
    where mirror.housing_barrier_topic(k) = any (p_ok)), '[]'::jsonb);
$$;

-- ---------------------------------------------------------------- T5.1 functions for pages (topic 'health')

create or replace function public.mirror_fa_get(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; v_self boolean; v_open uuid; v_last uuid;
begin
  r := mirror.allowed(v, 'health', 'view', null, 'functional_assessments', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := r ->> 'role' = 'self';
  select id into v_open from mirror.functional_assessments where individual_id = v and completed_at is null and is_self_report = v_self;
  select id into v_last from mirror.functional_assessments where individual_id = v and completed_at is not null order by completed_at desc limit 1;
  return jsonb_build_object(
    'role', r ->> 'role',
    'can_edit', mirror.may(v, 'health', 'edit'),
    'can_flag', not v_self and mirror.may(v, 'health', 'edit'),
    'open', case when v_open is not null then mirror.fa_json(v_open) end,
    'last', case when v_last is not null then mirror.fa_json(v_last) end,
    'review', (select jsonb_build_object('needed', f.professional_review_needed, 'note', f.review_note, 'by', f.review_by_role, 'at', f.review_at)
      from mirror.functional_assessments f where f.individual_id = v order by f.started_at desc limit 1),
    'history', coalesce((select jsonb_agg(mirror.fa_json(f.id) order by f.started_at desc) from mirror.functional_assessments f
      where f.individual_id = v and f.completed_at is not null), '[]'::jsonb));
end $$;

-- Save one activity in the open check-in (started on the first save). Empty level, preference and note = clear that activity.
create or replace function public.mirror_fa_save(p_part text, p_activity text, p_level text default null, p_preference text default null,
  p_note text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.target_individual(p_individual);
  g jsonb; v_self boolean; v_fa uuid;
  v_level text := nullif(btrim(coalesce(p_level, '')), '');
  v_pref text := nullif(btrim(coalesce(p_preference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if p_part not in ('adl', 'iadl') then raise exception 'Unknown part.' using errcode = '22023'; end if;
  g := mirror.require(v, 'health', 'edit', null, p_part || '_assessments', p_activity);
  v_self := g ->> 'role' = 'self';
  select id into v_fa from mirror.functional_assessments where individual_id = v and completed_at is null and is_self_report = v_self;
  if v_fa is null then
    if v_level is null and v_pref is null and v_note is null then return null; end if;
    insert into mirror.functional_assessments (individual_id, organization_id, assessed_by, assessed_by_role, is_self_report)
    values (v, nullif(g ->> 'organization_id', '')::uuid, lower(auth.email()), g ->> 'role', v_self) returning id into v_fa;
  end if;
  if p_part = 'adl' then
    if v_level is null and v_pref is null and v_note is null then
      delete from mirror.adl_assessments where functional_assessment_id = v_fa and activity = p_activity;
    else
      insert into mirror.adl_assessments (functional_assessment_id, activity, level, preference, note, answered_by_role)
      values (v_fa, p_activity, v_level, v_pref, v_note, g ->> 'role')
      on conflict (functional_assessment_id, activity) do update set level = excluded.level, preference = excluded.preference,
        note = excluded.note, answered_by_role = excluded.answered_by_role, updated_at = now();
    end if;
  else
    if v_level is null and v_pref is null and v_note is null then
      delete from mirror.iadl_assessments where functional_assessment_id = v_fa and activity = p_activity;
    else
      insert into mirror.iadl_assessments (functional_assessment_id, activity, level, preference, note, answered_by_role)
      values (v_fa, p_activity, v_level, v_pref, v_note, g ->> 'role')
      on conflict (functional_assessment_id, activity) do update set level = excluded.level, preference = excluded.preference,
        note = excluded.note, answered_by_role = excluded.answered_by_role, updated_at = now();
    end if;
  end if;
  update mirror.functional_assessments set updated_at = now() where id = v_fa;
  return mirror.fa_json(v_fa);
exception
  when check_violation then raise exception 'That choice is not on the list.' using errcode = '22023';
end $$;

-- Finish the open check-in: it is kept as it is (history), and the next save starts a new one.
create or replace function public.mirror_fa_finish(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb; v_fa uuid;
begin
  g := mirror.require(v, 'health', 'edit', null, 'functional_assessments', 'finish');
  select id into v_fa from mirror.functional_assessments where individual_id = v and completed_at is null and is_self_report = (g ->> 'role' = 'self');
  if v_fa is null then raise exception 'There is nothing to finish yet. Answer at least one activity first.' using errcode = 'P0002'; end if;
  if not exists (select 1 from mirror.adl_assessments where functional_assessment_id = v_fa)
     and not exists (select 1 from mirror.iadl_assessments where functional_assessment_id = v_fa) then
    raise exception 'There is nothing to finish yet. Answer at least one activity first.' using errcode = 'P0002';
  end if;
  update mirror.functional_assessments set completed_at = now(), updated_at = now() where id = v_fa;
  return mirror.fa_json(v_fa);
end $$;

-- A helper marks (or unmarks) "professional review needed" on the person's latest check-in. Never the person, never automatic.
create or replace function public.mirror_fa_review(p_needed boolean, p_note text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb; v_fa uuid;
begin
  g := mirror.require(v, 'health', 'edit', null, 'functional_assessments', 'review');
  if g ->> 'role' = 'self' then raise exception 'Only someone helping you can mark this.' using errcode = '42501'; end if;
  select id into v_fa from mirror.functional_assessments where individual_id = v order by started_at desc limit 1;
  if v_fa is null then raise exception 'There is no check-in to mark yet.' using errcode = 'P0002'; end if;
  update mirror.functional_assessments set professional_review_needed = coalesce(p_needed, false),
    review_note = case when coalesce(p_needed, false) then nullif(btrim(coalesce(p_note, '')), '') end,
    review_by_role = g ->> 'role', review_at = now(), updated_at = now() where id = v_fa;
  return mirror.fa_json(v_fa);
end $$;

-- ---------------------------------------------------------------- T5.2 functions for pages (topic 'general', parts health / legal)

create or replace function public.mirror_housing_get(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; v_ok text[] := array['general']; c text; p mirror.housing_profiles;
begin
  r := mirror.allowed(v, 'general', 'view', null, 'housing_profiles', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  foreach c in array array['health', 'mental_health', 'safety', 'legal'] loop
    if (mirror.allowed(v, c, 'view', null, 'housing_profiles', c) ->> 'ok')::boolean then v_ok := v_ok || c; end if;
  end loop;
  select * into p from mirror.housing_profiles where individual_id = v;
  return jsonb_build_object(
    'role', r ->> 'role',
    'can_edit', mirror.may(v, 'general', 'edit'),
    'can_edit_health', mirror.may(v, 'health', 'edit'),
    'can_edit_legal', mirror.may(v, 'legal', 'edit'),
    'can_flag', r ->> 'role' <> 'self' and mirror.may(v, 'general', 'edit'),
    'sees', to_jsonb(v_ok),
    'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'key', o.key, 'title', o.title, 'summary', o.summary) order by o.sort) from mirror.housing_options o where o.active),
    'profile', case when p.individual_id is null then null else jsonb_build_object(
      'current_arrangement', case when mirror.housing_arrangement_topic(p.current_arrangement) = any (v_ok) then p.current_arrangement end,
      'current_private', p.current_arrangement is not null and not (mirror.housing_arrangement_topic(p.current_arrangement) = any (v_ok)),
      'current_note', p.current_note,
      'preferred', coalesce((select jsonb_agg(o.key order by o.sort) from mirror.housing_options o where o.id = any (p.preferred_option_ids)), '[]'::jsonb),
      'barriers', jsonb_build_object('keys', mirror.housing_keys_visible(p.barriers, v_ok), 'note', p.barriers -> 'note',
        'hidden', jsonb_array_length(coalesce(p.barriers -> 'keys', '[]'::jsonb)) - jsonb_array_length(mirror.housing_keys_visible(p.barriers, v_ok))),
      'accessibility', case when 'health' = any (v_ok) then p.accessibility_needs else jsonb_build_object('private', true) end,
      'professional_review_needed', p.professional_review_needed, 'review_note', p.review_note, 'review_by', p.review_by_role, 'review_at', p.review_at,
      'updated_at', p.updated_at, 'updated_by', p.updated_by_role) end,
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'from_on', h.from_on, 'to_on', h.to_on, 'arrangement', h.arrangement,
        'city', h.city, 'note', h.note, 'private', h.sensitive_category, 'by', h.created_by_role) order by h.from_on desc nulls last, h.created_at desc)
      from mirror.housing_history h where h.individual_id = v
        and mirror.housing_arrangement_topic(h.arrangement) = any (v_ok) and (h.sensitive_category is null or h.sensitive_category = any (v_ok))), '[]'::jsonb),
    'history_hidden', (select count(*) from mirror.housing_history h where h.individual_id = v
        and not (mirror.housing_arrangement_topic(h.arrangement) = any (v_ok) and (h.sensitive_category is null or h.sensitive_category = any (v_ok)))));
end $$;

-- Save the profile. Only the fields present in p change. A helper without health or legal shared cannot see or change those parts,
-- and their save keeps them exactly as they were.
create or replace function public.mirror_housing_save(p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.target_individual(p_individual);
  g jsonb; old mirror.housing_profiles; v_ok text[] := array['general']; v_new text[]; v_keep text[]; v_ids uuid[]; v_bad text; v_arr text;
begin
  g := mirror.require(v, 'general', 'edit', null, 'housing_profiles', null);
  if mirror.may(v, 'health', 'edit') then v_ok := v_ok || 'health'::text; end if;
  if mirror.may(v, 'legal', 'edit') then v_ok := v_ok || 'legal'::text; end if;
  insert into mirror.housing_profiles (individual_id, updated_by_role) values (v, g ->> 'role') on conflict (individual_id) do nothing;
  select * into old from mirror.housing_profiles where individual_id = v for update;

  if p ? 'current_arrangement' then
    v_arr := nullif(btrim(coalesce(p ->> 'current_arrangement', '')), '');
    if not mirror.housing_arrangement_ok(v_arr) then raise exception 'Choose where you live from the list.' using errcode = '22023'; end if;
    if not (mirror.housing_arrangement_topic(old.current_arrangement) = any (v_ok)) or not (mirror.housing_arrangement_topic(v_arr) = any (v_ok)) then
      raise exception 'That part is private: the person has not shared it with your organization.' using errcode = '42501';
    end if;
    update mirror.housing_profiles set current_arrangement = v_arr where individual_id = v;
  end if;
  if p ? 'current_note' then
    update mirror.housing_profiles set current_note = nullif(btrim(coalesce(p ->> 'current_note', '')), '') where individual_id = v;
  end if;
  if p ? 'preferred' then
    select array_agg(o.id), (select k from jsonb_array_elements_text(p -> 'preferred') k where k not in (select key from mirror.housing_options) limit 1)
      into v_ids, v_bad from mirror.housing_options o where o.key in (select jsonb_array_elements_text(p -> 'preferred'));
    if v_bad is not null then raise exception 'Choose living options from the list.' using errcode = '22023'; end if;
    update mirror.housing_profiles set preferred_option_ids = coalesce(v_ids, '{}') where individual_id = v;
  end if;
  if p ? 'barriers' then
    select array_agg(distinct k) into v_new from jsonb_array_elements_text(coalesce(p -> 'barriers' -> 'keys', '[]'::jsonb)) k;
    if exists (select 1 from unnest(coalesce(v_new, '{}')) k where k not in ('rent_cost', 'move_in_cost', 'credit', 'eviction', 'criminal_record', 'no_id',
        'income_proof', 'references', 'fit_needs', 'pets', 'household_size', 'location', 'waitlists', 'unfair', 'other')) then
      raise exception 'Choose from the list.' using errcode = '22023';
    end if;
    -- keep what the caller may not touch; take the caller's choice for the rest
    select array_agg(k) into v_keep from jsonb_array_elements_text(coalesce(old.barriers -> 'keys', '[]'::jsonb)) k where not (mirror.housing_barrier_topic(k) = any (v_ok));
    select array_agg(k) into v_new from unnest(coalesce(v_new, '{}')) k where mirror.housing_barrier_topic(k) = any (v_ok);
    update mirror.housing_profiles set barriers = jsonb_build_object('keys', to_jsonb(coalesce(v_keep, '{}') || coalesce(v_new, '{}')),
      'note', nullif(btrim(coalesce(p -> 'barriers' ->> 'note', '')), '')) where individual_id = v;
  end if;
  if p ? 'accessibility' then
    if not ('health' = any (v_ok)) then raise exception 'That part is private: the person has not shared it with your organization.' using errcode = '42501'; end if;
    select array_agg(distinct k) into v_new from jsonb_array_elements_text(coalesce(p -> 'accessibility' -> 'keys', '[]'::jsonb)) k;
    if exists (select 1 from unnest(coalesce(v_new, '{}')) k where k not in ('no_stairs', 'elevator', 'wheelchair', 'grab_bars', 'roll_in_shower',
        'wide_doors', 'visual_alarms', 'service_animal', 'quiet', 'near_care', 'other')) then
      raise exception 'Choose from the list.' using errcode = '22023';
    end if;
    update mirror.housing_profiles set accessibility_needs = jsonb_build_object('keys', to_jsonb(coalesce(v_new, '{}')),
      'note', nullif(btrim(coalesce(p -> 'accessibility' ->> 'note', '')), '')) where individual_id = v;
  end if;
  update mirror.housing_profiles set updated_by_role = g ->> 'role', updated_at = now() where individual_id = v;
  return jsonb_build_object('ok', true);
exception
  when check_violation then raise exception 'Something in that entry is too long or not on the list.' using errcode = '22023';
end $$;

-- Add (p.id empty) or change one place lived.
create or replace function public.mirror_housing_history_save(p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.target_individual(p_individual);
  g jsonb; v_id uuid := nullif(p ->> 'id', '')::uuid; h mirror.housing_history;
  v_arr text := nullif(btrim(coalesce(p ->> 'arrangement', '')), '');
  v_cat text := nullif(btrim(coalesce(p ->> 'private', '')), '');
  v_from date; v_to date;
begin
  g := mirror.require(v, 'general', 'edit', null, 'housing_history', coalesce(v_id::text, 'new'));
  if v_arr is null or not mirror.housing_arrangement_ok(v_arr) then raise exception 'Choose what kind of place it was.' using errcode = '22023'; end if;
  if v_cat is not null and v_cat not in ('health', 'mental_health', 'safety', 'legal') then raise exception 'Unknown topic.' using errcode = '22023'; end if;
  begin v_from := nullif(p ->> 'from_on', '')::date; v_to := nullif(p ->> 'to_on', '')::date;
  exception when others then raise exception 'Enter dates like 2024-03-01.' using errcode = '22023'; end;
  if v_from is not null and v_to is not null and v_to < v_from then raise exception 'The end date is before the start date.' using errcode = '22023'; end if;
  -- every topic the row touches must be the caller's to change (old row and new row)
  if mirror.housing_arrangement_topic(v_arr) <> 'general' then perform mirror.require(v, mirror.housing_arrangement_topic(v_arr), 'edit', null, 'housing_history', v_arr); end if;
  if v_cat is not null then perform mirror.require(v, v_cat, 'edit', null, 'housing_history', v_cat); end if;
  if v_id is null then
    insert into mirror.housing_history (individual_id, from_on, to_on, arrangement, city, note, sensitive_category, created_by_role)
    values (v, v_from, v_to, v_arr, nullif(btrim(coalesce(p ->> 'city', '')), ''), nullif(btrim(coalesce(p ->> 'note', '')), ''), v_cat, g ->> 'role') returning id into v_id;
  else
    select * into h from mirror.housing_history where id = v_id and individual_id = v for update;
    if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
    if mirror.housing_arrangement_topic(h.arrangement) <> 'general' then perform mirror.require(v, mirror.housing_arrangement_topic(h.arrangement), 'edit', null, 'housing_history', v_id::text); end if;
    if h.sensitive_category is not null then perform mirror.require(v, h.sensitive_category, 'edit', null, 'housing_history', v_id::text); end if;
    update mirror.housing_history set from_on = v_from, to_on = v_to, arrangement = v_arr, city = nullif(btrim(coalesce(p ->> 'city', '')), ''),
      note = nullif(btrim(coalesce(p ->> 'note', '')), ''), sensitive_category = v_cat, updated_at = now() where id = v_id;
  end if;
  return jsonb_build_object('id', v_id);
exception
  when check_violation then raise exception 'Something in that entry is too long or not on the list.' using errcode = '22023';
end $$;

create or replace function public.mirror_housing_history_delete(p_id uuid, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); h mirror.housing_history;
begin
  perform mirror.require(v, 'general', 'edit', null, 'housing_history', p_id::text);
  select * into h from mirror.housing_history where id = p_id and individual_id = v;
  if not found then raise exception 'Not found.' using errcode = 'P0002'; end if;
  if mirror.housing_arrangement_topic(h.arrangement) <> 'general' then perform mirror.require(v, mirror.housing_arrangement_topic(h.arrangement), 'edit', null, 'housing_history', p_id::text); end if;
  if h.sensitive_category is not null then perform mirror.require(v, h.sensitive_category, 'edit', null, 'housing_history', p_id::text); end if;
  delete from mirror.housing_history where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- A helper marks (or unmarks) "professional review needed" on the housing profile. Never the person, never automatic.
create or replace function public.mirror_housing_review(p_needed boolean, p_note text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb;
begin
  g := mirror.require(v, 'general', 'edit', null, 'housing_profiles', 'review');
  if g ->> 'role' = 'self' then raise exception 'Only someone helping you can mark this.' using errcode = '42501'; end if;
  insert into mirror.housing_profiles (individual_id, updated_by_role) values (v, g ->> 'role') on conflict (individual_id) do nothing;
  update mirror.housing_profiles set professional_review_needed = coalesce(p_needed, false),
    review_note = case when coalesce(p_needed, false) then nullif(btrim(coalesce(p_note, '')), '') end,
    review_by_role = g ->> 'role', review_at = now(), updated_at = now() where individual_id = v;
  return jsonb_build_object('ok', true);
end $$;

-- The person's own download of Phase 5 records (the Settings page adds it to mirror_my_export, which another session owns).
create or replace function public.mirror_my_export_living() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  perform mirror.audit(v, null, 'self', 'export', 'general', 'functional_housing', null);
  return jsonb_build_object(
    'everyday_activities', coalesce((select jsonb_agg(mirror.fa_json(f.id) order by f.started_at) from mirror.functional_assessments f where f.individual_id = v), '[]'::jsonb),
    'housing_profile', (select to_jsonb(h) - 'individual_id' || jsonb_build_object('preferred', coalesce((select jsonb_agg(o.key order by o.sort)
        from mirror.housing_options o where o.id = any (h.preferred_option_ids)), '[]'::jsonb)) - 'preferred_option_ids'
      from mirror.housing_profiles h where h.individual_id = v),
    'housing_history', coalesce((select jsonb_agg(to_jsonb(h) - 'individual_id' order by h.from_on nulls last, h.created_at)
      from mirror.housing_history h where h.individual_id = v), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- triggers, row security, grants

create trigger functional_assessments_touch before update on mirror.functional_assessments for each row execute function mirror.touch();
create trigger housing_options_touch before update on mirror.housing_options for each row execute function mirror.touch();

alter table mirror.functional_assessments enable row level security;
alter table mirror.adl_assessments enable row level security;
alter table mirror.iadl_assessments enable row level security;
alter table mirror.housing_options enable row level security;
alter table mirror.housing_profiles enable row level security;
alter table mirror.housing_history enable row level security;

revoke all on mirror.functional_assessments, mirror.adl_assessments, mirror.iadl_assessments, mirror.housing_options, mirror.housing_profiles,
  mirror.housing_history from public, anon, authenticated;
grant all on mirror.functional_assessments, mirror.adl_assessments, mirror.iadl_assessments, mirror.housing_options, mirror.housing_profiles,
  mirror.housing_history to service_role;

revoke all on function mirror.functional_finished_frozen(), mirror.housing_arrangement_ok(text), mirror.housing_arrangement_topic(text),
  mirror.housing_barrier_topic(text), mirror.fa_json(uuid), mirror.housing_keys_visible(jsonb, text[]) from public, anon, authenticated;
grant execute on function mirror.functional_finished_frozen(), mirror.housing_arrangement_ok(text), mirror.housing_arrangement_topic(text),
  mirror.housing_barrier_topic(text), mirror.fa_json(uuid), mirror.housing_keys_visible(jsonb, text[]) to service_role;

revoke all on function public.mirror_fa_get(uuid), public.mirror_fa_save(text, text, text, text, text, uuid), public.mirror_fa_finish(uuid),
  public.mirror_fa_review(boolean, text, uuid), public.mirror_housing_get(uuid), public.mirror_housing_save(jsonb, uuid),
  public.mirror_housing_history_save(jsonb, uuid), public.mirror_housing_history_delete(uuid, uuid), public.mirror_housing_review(boolean, text, uuid),
  public.mirror_my_export_living() from public, anon;
grant execute on function public.mirror_fa_get(uuid), public.mirror_fa_save(text, text, text, text, text, uuid), public.mirror_fa_finish(uuid),
  public.mirror_fa_review(boolean, text, uuid), public.mirror_housing_get(uuid), public.mirror_housing_save(jsonb, uuid),
  public.mirror_housing_history_save(jsonb, uuid), public.mirror_housing_history_delete(uuid, uuid), public.mirror_housing_review(boolean, text, uuid),
  public.mirror_my_export_living() to authenticated, service_role;
