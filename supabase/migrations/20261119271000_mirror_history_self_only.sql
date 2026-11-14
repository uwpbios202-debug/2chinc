-- The Human Mirror: earlier answers are for the person only (Stephen 11/12/2026, gap list item 12, option A).
-- Before: anyone allowed to view a topic (an organization working with the person) got every earlier answer.
-- Now: the person gets the full history; anyone else gets only the current answer, if there is one.
-- Same permission check and audit as before (mirror.allowed logs the look). No new table, so no grants beyond the function's.

create or replace function public.mirror_answers_history(p_set_key text, p_question_key text, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  q mirror.reflection_questions;
  r jsonb;
  v_self boolean;
begin
  select qq.* into q from mirror.reflection_questions qq join mirror.question_sets s on s.id = qq.set_id where s.key = p_set_key and qq.key = p_question_key;
  if not found then raise exception 'That question is not available.' using errcode = 'P0002'; end if;
  r := mirror.allowed(v_id, q.category, 'view', null, 'assessment_responses', q.id::text);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  return coalesce((select jsonb_agg(jsonb_build_object('value', x.value, 'state', x.state, 'note', x.note, 'by', x.answered_by_role,
      'at', x.answered_at, 'current', x.superseded_at is null) order by x.answered_at desc, x.id desc)
    from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
    where a.individual_id = v_id and x.question_id = q.id
      and (v_self or x.superseded_at is null)), '[]'::jsonb);
end $$;

revoke all on function public.mirror_answers_history(text, text, uuid) from public, anon;
grant execute on function public.mirror_answers_history(text, text, uuid) to authenticated, service_role;
