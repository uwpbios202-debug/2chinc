CREATE OR REPLACE FUNCTION mirror.resource_matches(p_individual uuid, p_self boolean)
 RETURNS TABLE(need_id uuid, program_id text, rank integer, score integer, why jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
$function$

