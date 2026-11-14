-- The Human Mirror: the person can clear their own current answer (Phase 3 gap list item 12, Stephen 11/12/2026).
-- Clearing puts the question back to "not answered": the current answer row is marked superseded (the one change the
-- append-only trigger allows) and no new row is added, so organizations no longer see an answer to that question.
-- The old answer stays in the person's history (answers are kept until the whole Mirror is deleted, D-18).
-- Own Mirror only: mirror.me() refuses View as and anyone without a Mirror; coordinators cannot clear.
-- Logged as 'answer_clear' (the person's own action; not shown in "Who looked"). No new table, so no table grants.

create or replace function public.mirror_answer_clear(p_set_key text, p_question_key text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.me();
  s mirror.question_sets;
  q mirror.reflection_questions;
  v_assess uuid;
  v_cur bigint;
begin
  select * into s from mirror.question_sets where key = p_set_key and active;
  if not found then raise exception 'Those questions are not available.' using errcode = 'P0002'; end if;
  select * into q from mirror.reflection_questions where set_id = s.id and key = p_question_key;
  if not found then raise exception 'That question is not available.' using errcode = 'P0002'; end if;

  select id into v_assess from mirror.assessments where individual_id = v and set_id = s.id;
  if v_assess is not null then
    select id into v_cur from mirror.assessment_responses
     where assessment_id = v_assess and question_id = q.id and superseded_at is null;
    if v_cur is not null then
      update mirror.assessment_responses set superseded_at = now() where id = v_cur;
      update mirror.assessments set updated_at = now() where id = v_assess;
      perform mirror.audit(v, null, 'self', 'answer_clear', q.category, 'assessment_responses', q.id::text);
    end if;
  end if;

  return jsonb_build_object('cleared', v_cur is not null,
    'answered', (select count(*) from mirror.current_answers ca where ca.individual_id = v and ca.set_key = s.key),
    'questions', (select count(*) from mirror.reflection_questions x where x.set_id = s.id and x.active));
end $$;

revoke all on function public.mirror_answer_clear(text, text) from public, anon;
grant execute on function public.mirror_answer_clear(text, text) to authenticated, service_role;
