-- The Human Mirror T7.2 follow-up (Stephen 11/13/2026, on D-32):
--   (e) "eligibility be confirmed only by an organization member - yes"  -> unchanged, now CONFIRMED.
--   (d) "give them the choice to 'share' with others"                   -> resource_profiles.shared (off by default). When on,
--       organizations the person works with (and may see everyday topics) see the place and groups, read-only, and the person's
--       matches on their screens use them too. Only the person changes them or the choice.
--   (a) "no limit but ranked in order of likelihood - view choices top 1, top 3 etc" -> every match is returned, best fit first,
--       each with its score and the plain reasons for its place; the page offers Top 1 / Top 3 / Top 5 / All.
-- Ranking ("best fit first", never a promise of eligibility): +3 for each group the program is written for that the person is in;
-- +2 when the program is not written for particular groups; -1 when it is written only for groups the person has not said either way
-- (0, with the groups named, when it is written for broader groups such as low-income working);
-- directory confidence +2 "Verified – Current", +1 "Verified – Limited", -1 "Unverified Lead"; +1 when the person can apply
-- themselves. Ties: program name. Each program is still listed once, under the most urgent need it fits.
-- No table is created (one column added), so no new grants; replaced functions keep theirs, re-granted below where the signature changed.

alter table mirror.resource_profiles add column shared boolean not null default false;

-- ---------------------------------------------------------------- groups that count (the person's own, or shared ones)
create or replace function mirror.resource_groups(p_individual uuid, p_self boolean) returns text[]
language sql stable set search_path = mirror, public as $$
  with use_it as (select p_self or coalesce((select rp.shared from mirror.resource_profiles rp where rp.individual_id = p_individual), false) ok)
  select array(select distinct g from (
    select unnest(coalesce((select rp.groups from mirror.resource_profiles rp where rp.individual_id = p_individual), '{}')) g
      where (select ok from use_it)
    union all
    select 'Families with children' where (select ok from use_it) and exists (select 1 from mirror.household_members h
      where h.individual_id = p_individual and h.relationship = 'child' and h.lives_with)
    union all
    select 'Seniors' where (select ok from use_it) and exists (select 1 from mirror.individuals i
      where i.id = p_individual and i.birth_year is not null and extract(year from now())::int - i.birth_year >= 62)) x);
$$;

-- ---------------------------------------------------------------- matches, all of them, ranked
drop function mirror.resource_matches(uuid, boolean);
create function mirror.resource_matches(p_individual uuid, p_self boolean)
  returns table (need_id uuid, program_id text, rank int, score int, why jsonb)
language sql stable security definer set search_path = mirror, public as $$
  with prof as (
    select rp.place, rp.groups_answered answered from mirror.resource_profiles rp
     where rp.individual_id = p_individual and (p_self or rp.shared)),
  pf as (
    select (select place from prof) place, coalesce((select answered from prof), false) answered,
           mirror.resource_groups(p_individual, p_self) groups),
  open_needs as (
    select n.id, n.dimension_key,
           row_number() over (order by array_position(array['urgent', 'soon', 'later'], n.urgency), n.created_at) need_order
      from mirror.needs n
     where n.individual_id = p_individual and n.status in ('identified', 'planning', 'in_progress') and n.dimension_key is not null),
  cand as (
    select distinct on (p.program_id) o.id need_id, o.need_order, p.program_id, p.program_name, p.verification_status, p.self_referral
      from open_needs o
      join mirror.resource_categories rc on rc.dimension_key = o.dimension_key
      join public.chpms_programs p on p.program_id = rc.chpms_program_id
      join public.chpms_orgs g on g.org_id = p.org_id
      cross join pf
     where coalesce(g.our_relationship, '') <> 'do_not_refer'
       and mirror.place_served(g.service_area, pf.place)
       and not exists (select 1 from mirror.resource_suggestions s where s.individual_id = p_individual and s.chpms_program_id = p.program_id)
       and not (pf.answered and exists (select 1 from public.chpms_program_pops pp where pp.program_id = p.program_id)
                and not exists (select 1 from public.chpms_program_pops pp where pp.program_id = p.program_id
                                 and (pp.population = any (pf.groups) or pp.population not in
                                      ('Veterans', 'Seniors', 'Returning citizens', 'Families with children', 'Disabilities'))))
     order by p.program_id, o.need_order),
  scored as (
    select c.need_id, c.program_id, c.program_name, w.why, coalesce((select sum((e ->> 'points')::int) from jsonb_array_elements(w.why) e), 0)::int score
      from cand c cross join pf
      cross join lateral (select coalesce(jsonb_agg(r) filter (where r is not null), '[]'::jsonb) why from (
        select jsonb_build_object('points', 3, 'reason', 'Written for ' || lower(pp.population) || ', and that fits you') r
          from public.chpms_program_pops pp where pp.program_id = c.program_id and pp.population = any (pf.groups)
        union all
        select jsonb_build_object('points', 2, 'reason', 'Open to anyone, not only certain groups')
         where not exists (select 1 from public.chpms_program_pops pp where pp.program_id = c.program_id)
        union all
        select case when count(*) filter (where pp.population not in ('Veterans', 'Seniors', 'Returning citizens', 'Families with children', 'Disabilities')) = 0
                    then jsonb_build_object('points', -1, 'reason', 'Written only for ' || string_agg(lower(pp.population), ', ' order by pp.population))
                    else jsonb_build_object('points', 0, 'reason', 'Written for ' || string_agg(lower(pp.population), ', ' order by pp.population)) end
          from public.chpms_program_pops pp where pp.program_id = c.program_id
         having count(*) > 0 and count(*) filter (where pp.population = any (pf.groups)) = 0
        union all
        select case when c.verification_status ~* 'verified.*current' then jsonb_build_object('points', 2, 'reason', 'The directory recently confirmed this program')
                    when c.verification_status ~* 'verified.*limited' then jsonb_build_object('points', 1, 'reason', 'The directory partly confirmed this program')
                    when c.verification_status ~* 'unverified' then jsonb_build_object('points', -1, 'reason', 'The directory has not confirmed this program yet') end
        union all
        select jsonb_build_object('points', 1, 'reason', 'You can apply yourself') where c.self_referral ~* '^yes'
        union all
        select jsonb_build_object('points', 0, 'reason', 'Needs a referral from an agency') where c.self_referral ~* '^no') x) w)
  select s.need_id, s.program_id,
         (row_number() over (partition by s.need_id order by s.score desc, lower(s.program_name)))::int, s.score, s.why
    from scored s;
$$;
revoke all on function mirror.resource_matches(uuid, boolean) from public, anon, authenticated;
grant execute on function mirror.resource_matches(uuid, boolean) to service_role;

-- ---------------------------------------------------------------- the page
create or replace function public.mirror_resources(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_self boolean;
  v_ok text[] := '{}';
  c text;
  v_matches jsonb;
  v_prof mirror.resource_profiles;
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
  select * into v_prof from mirror.resource_profiles where individual_id = v_id;
  if not v_self and coalesce(v_prof.shared, false) then
    perform mirror.allowed(v_id, 'general', 'view', null, 'resource_profiles', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('need_id', n.id, 'need_title', n.title, 'urgency', n.urgency,
      'dimension', n.dimension_key, 'dimension_title', (select d.title from mirror.dimensions d where d.key = n.dimension_key),
      'private', n.category <> 'general',
      'programs', coalesce((select jsonb_agg(mirror.resource_program_json(m.program_id) || jsonb_build_object('rank', m.rank, 'score', m.score, 'why', m.why)
                                             order by m.rank)
                              from mirror.resource_matches(v_id, v_self) m where m.need_id = n.id), '[]'::jsonb))
      order by array_position(array['urgent', 'soon', 'later'], n.urgency), n.created_at), '[]'::jsonb)
    into v_matches
    from mirror.needs n
   where n.individual_id = v_id and n.status in ('identified', 'planning', 'in_progress') and n.dimension_key is not null
     and n.category = any (v_ok) and mirror.may(v_id, n.category, 'edit');

  return jsonb_build_object(
    'self', v_self,
    'profile', case when v_self or coalesce(v_prof.shared, false) then jsonb_build_object('place', v_prof.place,
                 'groups', to_jsonb(coalesce(v_prof.groups, '{}')), 'groups_answered', coalesce(v_prof.groups_answered, false),
                 'shared', coalesce(v_prof.shared, false)) end,
    'household_groups', case when v_self or coalesce(v_prof.shared, false) then to_jsonb(array(select x from unnest(mirror.resource_groups(v_id, v_self)) x
                          where x <> all (coalesce(v_prof.groups, '{}')))) end,
    'can_confirm', not v_self,
    'list', coalesce((select jsonb_agg(mirror.resource_suggestion_json(s) order by
              array_position(array['enrolled', 'eligibility_confirmed', 'applied', 'suggested', 'declined'], s.status), s.created_at)
       from mirror.resource_suggestions s where s.individual_id = v_id and s.category = any (v_ok)), '[]'::jsonb),
    'matches', v_matches);
end $$;

-- ---------------------------------------------------------------- the person's place, groups and the share choice (the person only)
drop function public.mirror_resource_profile_save(text, text[]);
create function public.mirror_resource_profile_save(p_place text, p_groups text[] default null, p_shared boolean default null) returns jsonb
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
  insert into mirror.resource_profiles (individual_id, place, groups, groups_answered, shared)
  values (v_id, v_place, v_groups, p_groups is not null, coalesce(p_shared, false))
  on conflict (individual_id) do update set place = excluded.place,
    groups = case when p_groups is null then mirror.resource_profiles.groups else excluded.groups end,
    groups_answered = mirror.resource_profiles.groups_answered or excluded.groups_answered,
    shared = coalesce(p_shared, mirror.resource_profiles.shared);
  return (select jsonb_build_object('place', rp.place, 'groups', to_jsonb(rp.groups), 'groups_answered', rp.groups_answered, 'shared', rp.shared)
            from mirror.resource_profiles rp where rp.individual_id = v_id);
end $$;
revoke all on function public.mirror_resource_profile_save(text, text[], boolean) from public, anon;
grant execute on function public.mirror_resource_profile_save(text, text[], boolean) to authenticated, service_role;

-- ---------------------------------------------------------------- the person's own download (adds the share choice)
create or replace function public.mirror_my_export_resources() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.require(v, 'general', 'view', null, 'resource_suggestions', null);
  return jsonb_build_object(
    'where_and_groups', (select jsonb_build_object('place', rp.place, 'groups', to_jsonb(rp.groups), 'shared_with_organizations', rp.shared, 'changed', rp.updated_at)
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
