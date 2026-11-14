-- The Human Mirror, Phase 3 analysis finding 8 (Stephen, 11/13/2026): every answer ever given could be wiped with TRUNCATE.
-- The append-only trigger (assessment_responses_append_only) works row by row on UPDATE and DELETE; TRUNCATE skips row triggers.
-- Same cure as Phase 2 fix 14 for the audit log (migration 20261119266000).
-- Checked live 11/13: TRUNCATE on mirror.assessment_responses is held by postgres (owner) and service_role; anon and authenticated hold nothing.
--  1. service_role loses TRUNCATE on mirror.assessment_responses (it keeps the rest; edge functions never need TRUNCATE).
--  2. A statement trigger refuses TRUNCATE for everyone, the owner included (also when reached by TRUNCATE ... CASCADE from
--     mirror.assessments), unless the trigger itself is deliberately dropped.
-- Deleting a whole Mirror (D-18) is unaffected: it uses DELETE, which cascades row by row and the append-only trigger allows.
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule).

revoke truncate on mirror.assessment_responses from service_role;

create or replace function mirror.answers_no_truncate() returns trigger language plpgsql set search_path = mirror as $$
begin raise exception 'Mirror answers cannot be emptied.' using errcode = '42501'; end $$;

revoke all on function mirror.answers_no_truncate() from public, anon, authenticated;

create trigger assessment_responses_no_truncate before truncate on mirror.assessment_responses
  for each statement execute function mirror.answers_no_truncate();
