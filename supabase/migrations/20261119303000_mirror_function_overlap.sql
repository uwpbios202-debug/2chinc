-- Human Mirror Phase 5, P5-03 (Stephen 11/13/2026: "remove the overlap").
-- The Phase 3 Function reflection asked 9 light questions that the Phase 5 Everyday activities page now asks in full
-- (ADL / IADL, with level and the person's own preference). Those 9 are retired here; the reflection keeps the 3 that
-- no Phase 5 list covers: forms and paperwork, keeping appointments, and the open "where would a little help" question.
--
-- Retired = active false (never deleted): mirror_sets / mirror_set_get / mirror_answer_save already skip inactive
-- questions, the question_versions history stays, and any answer ever given stays in the person's history and export.
-- Live check 11/13/2026: no one has answered these questions yet.
--
--   meals          -> IADL meal_prep        shopping     -> IADL shopping       medicine  -> IADL medication
--   bills          -> IADL finances         getting_around -> IADL transportation
--   housekeeping   -> IADL housekeeping     laundry      -> IADL laundry        phone     -> IADL devices
--   personal_care  -> ADL bathing + dressing

update mirror.reflection_questions q
   set active = false
  from mirror.question_sets s
 where s.id = q.set_id
   and s.key = 'reflection_function'
   and q.key in ('meals', 'shopping', 'medicine', 'bills', 'getting_around', 'housekeeping', 'laundry', 'phone', 'personal_care')
   and q.active;

update mirror.question_sets
   set intro = 'Paperwork, appointments, and where a little help would make life easier. How everyday activities go (meals, shopping, medicine, money, getting around, home, personal care) is on Everyday activities. Never a diagnosis.'
 where key = 'reflection_function';

do $$
declare n int;
begin
  select count(*) into n from mirror.reflection_questions q join mirror.question_sets s on s.id = q.set_id
   where s.key = 'reflection_function' and q.active;
  if n <> 3 then raise exception 'Function reflection should keep 3 active questions, has %', n; end if;
end $$;
