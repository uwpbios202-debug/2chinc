-- mirror.need_suggestions_for: live body (20261119333000 and later); NEW branch 4 for the Phase 11 topic help questions.
CREATE OR REPLACE FUNCTION mirror.need_suggestions_for(v uuid)
 RETURNS TABLE(from_key text, title text, dimension_key text, urgency text, source text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'mirror', 'public'
AS $function$
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
    union all
    -- 4. Phase 11: a topic's own help question ("Would you like help finding treatment or recovery support?"), named after the topic
    select 'q:' || ca.set_key || ':' || ca.question_key,
      'Help with: ' || case ca.question_key when 'su_help' then 'treatment or recovery support' when 'gl_help' then 'grief support'
        when 'ji_help' then 'a record, court or supervision' when 'vet_help' then 'veterans'' services' when 'dc_help' then 'debt or credit'
        when 'cg_help' then 'childcare or caregiving' when 'hf_help' then 'furniture and household things' end,
      case when ca.category = 'general' then qs.dimension_key else mirror.category_dimension(ca.category) end,
      case when ca.value #>> '{}' = 'now' then 'soon' else 'later' end, q.prompt, 4, ca.answered_at
    from mirror.current_answers ca
    join mirror.question_sets qs on qs.key = ca.set_key and qs.kind = 'dimension'
    join mirror.reflection_questions q on q.set_id = qs.id and q.key = ca.question_key
    where ca.individual_id = v and ca.question_key in ('su_help', 'gl_help', 'ji_help', 'vet_help', 'dc_help', 'cg_help', 'hf_help')
      and ca.state = 'answered' and ca.value #>> '{}' in ('now', 'later')
  )
  -- one suggestion per key (an area named in both places: the life area's own answer wins), minus those already added or set aside
  select distinct on (s.from_key) s.from_key, s.title, s.dimension_key, s.urgency, s.source
  from s
  where not exists (select 1 from mirror.needs n where n.individual_id = v and n.from_key = s.from_key)
    and not exists (select 1 from mirror.need_suggestion_dismissals x where x.individual_id = v and x.from_key = s.from_key)
  order by s.from_key, s.kind, s.at desc;
$function$
;
