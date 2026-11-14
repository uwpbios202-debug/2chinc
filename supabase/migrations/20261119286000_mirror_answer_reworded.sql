-- The Human Mirror, P3-06b (Stephen 11/13/2026: "go ahead"): the answering screen can say when an answer was given to an
-- earlier wording of the question (follow-up to fix 6, migration 20261119282000).
--  1. mirror.current_answers gains question_version as its LAST column (existing columns and their order unchanged, so every
--     user of the view keeps working).
--  2. mirror_set_get (live body of 11/13, migration 20261119190000) adds to each question 'version', and to each answer 'version'
--     (the wording it was given to) and 'reworded' (true when the question has been reworded since). Nothing else changes.
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule); the view keeps its grants.

create or replace view mirror.current_answers as
  select a.individual_id, s.key as set_key, s.kind, q.key as question_key, q.category, r.value, r.state, r.note, r.answered_by_role, r.answered_at,
         r.question_version
  from mirror.assessment_responses r
  join mirror.assessments a on a.id = r.assessment_id
  join mirror.question_sets s on s.id = a.set_id
  join mirror.reflection_questions q on q.id = r.question_id
  where r.superseded_at is null;

CREATE OR REPLACE FUNCTION public.mirror_set_get(p_set_key text, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $setget$
declare
  v_id uuid := mirror.target_individual(p_individual);
  s mirror.question_sets;
  v_ok text[] := '{}';
  v_edit text[] := '{}';
  c text;
begin
  select * into s from mirror.question_sets where key = p_set_key and active;
  if not found then raise exception 'Those questions are not available.' using errcode = 'P0002'; end if;
  for c in select distinct q.category from mirror.reflection_questions q where q.set_id = s.id and q.active loop
    if (mirror.allowed(v_id, c, 'view', null, 'assessment_responses', s.key) ->> 'ok')::boolean then v_ok := v_ok || c; end if;
    if mirror.may(v_id, c, 'edit') then v_edit := v_edit || c; end if;
  end loop;
  if cardinality(v_ok) = 0 and exists (select 1 from mirror.reflection_questions q where q.set_id = s.id and q.active) then
    raise exception 'The person has not shared these answers with your organization.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'set', jsonb_build_object('key', s.key, 'kind', s.kind, 'title', s.title, 'intro', s.intro, 'version', s.version,
      'reflection', s.reflection_key, 'dimension', s.dimension_key),
    'questions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', q.id, 'key', q.key, 'prompt', q.prompt, 'help', q.help, 'answer_type', q.answer_type, 'options', q.options,
        'category', q.category, 'private', q.category <> 'general', 'version', q.version,
        'hidden', not (q.category = any (v_ok)),
        'can_edit', q.category = any (v_edit),
        'answer', case when q.category = any (v_ok) then (
            select jsonb_build_object('value', ca.value, 'state', ca.state, 'note', ca.note, 'by', ca.answered_by_role, 'at', ca.answered_at,
              'version', ca.question_version, 'reworded', ca.question_version <> q.version)
            from mirror.current_answers ca where ca.individual_id = v_id and ca.set_key = s.key and ca.question_key = q.key) end)
      order by q.sort, q.key)
      from mirror.reflection_questions q where q.set_id = s.id and q.active), '[]'::jsonb));
end $setget$
;
