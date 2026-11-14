-- The Human Mirror, Phase 2 fix 14 of 15 (Stephen, 11/13/2026): the audit log could be wiped with TRUNCATE.
-- The append-only trigger (audit_logs_append_only) covers UPDATE and DELETE row by row; TRUNCATE skips row triggers.
-- Checked live 11/13: TRUNCATE was held by postgres (owner) and service_role; anon and authenticated hold nothing.
--  1. service_role loses TRUNCATE on mirror.audit_logs (it keeps the rest; edge functions never need TRUNCATE).
--  2. A statement trigger refuses TRUNCATE for everyone, the owner included, unless the trigger itself is deliberately dropped.
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule).

revoke truncate on mirror.audit_logs from service_role;

create or replace function mirror.audit_no_truncate() returns trigger language plpgsql set search_path = mirror as $$
begin raise exception 'The Mirror audit log cannot be emptied.' using errcode = '42501'; end $$;

create trigger audit_logs_no_truncate before truncate on mirror.audit_logs
  for each statement execute function mirror.audit_no_truncate();
