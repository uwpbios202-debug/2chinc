-- The Human Mirror, Phase 3 analysis finding 7 (Stephen, 11/13/2026): after a save, mirror_answer_save returned how many
-- questions in the set are answered, counting private questions the caller may not see. A coordinator could learn that a
-- person had answered, for example, "What are you afraid of?" without being shared that topic (only the count, never the answer).
-- Now both counts ('answered', 'questions') include only the categories the caller may view, exactly as mirror_sets counts them
-- (quiet mirror.may probe, never logged as a look). Everything else is the live body of 11/13 (migration 20261119190000) unchanged.
-- The answering screen counts on its own and does not read these numbers, so nothing on screen changes.
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule); the function keeps its grants.

create or replace function public.mirror_answer_save(p_set_key text, p_question_key text, p_value jsonb, p_state text default 'answered',
  p_note text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  s mirror.question_sets;
  q mirror.reflection_questions;
  g jsonb;
  v_assess uuid;
  v_val jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  cur mirror.assessment_responses;
  v_ok text[] := '{}';
  c text;
begin
  select * into s from mirror.question_sets where key = p_set_key and active;
  if not found then raise exception 'Those questions are not available.' using errcode = 'P0002'; end if;
  select * into q from mirror.reflection_questions where set_id = s.id and key = p_question_key and active;
  if not found then raise exception 'That question is not available.' using errcode = 'P0002'; end if;
  if p_state not in ('answered', 'unknown', 'not_applicable', 'prefer_not', 'needs_help') then raise exception 'Unknown answer state.' using errcode = '22023'; end if;
  g := mirror.require(v_id, q.category, 'edit', null, 'assessment_responses', q.id::text);
  v_val := case when p_state = 'answered' then mirror.clean_answer(q, p_value) end;

  insert into mirror.assessments (individual_id, set_id, set_version, organization_id, conducted_by)
  values (v_id, s.id, s.version, (g ->> 'organization_id')::uuid, lower(auth.email()))
  on conflict (individual_id, set_id) do update set updated_at = now()
  returning id into v_assess;

  select * into cur from mirror.assessment_responses where assessment_id = v_assess and question_id = q.id and superseded_at is null;
  if found and cur.state = p_state and cur.value is not distinct from v_val and cur.note is not distinct from v_note then
    null;   -- unchanged: keep the history clean
  else
    if found then update mirror.assessment_responses set superseded_at = now() where id = cur.id; end if;
    insert into mirror.assessment_responses (assessment_id, question_id, value, state, note, answered_by, answered_by_role)
    values (v_assess, q.id, v_val, p_state, v_note, lower(auth.email()), g ->> 'role');
  end if;

  -- counts only over what the caller may see (as mirror_sets): counting is not a look, so the quiet probe is used
  for c in select distinct x.category from mirror.reflection_questions x where x.set_id = s.id and x.active loop
    if mirror.may(v_id, c, 'view') then v_ok := v_ok || c; end if;
  end loop;

  return jsonb_build_object('saved', true,
    'answered', (select count(*) from mirror.current_answers ca
                 join mirror.reflection_questions x on x.set_id = s.id and x.key = ca.question_key
                 where ca.individual_id = v_id and ca.set_key = s.key and x.active and x.category = any (v_ok)),
    'questions', (select count(*) from mirror.reflection_questions x where x.set_id = s.id and x.active and x.category = any (v_ok)));
end $$;
