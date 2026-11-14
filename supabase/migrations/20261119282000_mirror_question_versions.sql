-- The Human Mirror, Phase 3 analysis finding 6 (Stephen, 11/13/2026): changing a question's wording would change the meaning of
-- answers already given. Answers pointed at the question, not at the wording the person saw, and questions had no version.
-- The prompt (Part 8): "Preserve historical assessment and financial snapshots."
--  1. mirror.reflection_questions gets `version` (1 for all 268 today).
--  2. mirror.question_versions keeps every wording a question has had (prompt, help, answer type, choices, topic). Append-only:
--     no UPDATE, no DELETE (except together with its question), no TRUNCATE.
--  3. Changing a question's prompt, help, answer type, choices or topic raises its version by 1 and records the new wording
--     (trigger). The version cannot be set by hand.
--  4. Every answer stores the version the person saw (`question_version`, set by trigger on insert from the question's current
--     version; all 14 answers today are version 1). Foreign key (question_id, question_version) -> question_versions.
--  5. The append-only rule on answers now also keeps question_version and answered_by_role unchanged when an answer is superseded.
--  6. mirror_answers_history and mirror_my_export give each answer the wording it was given to (live bodies of 11/13:
--     migrations 20261119271000 and 20261119240000, otherwise unchanged).
-- Grants (CLAUDE.md, 10/30/2026 rule): the new table is for service_role only (pages reach it through the functions above);
-- anon and authenticated get nothing. Row security on.

-- ---------------------------------------------------------------- 1-2 versions and the wording history
alter table mirror.reflection_questions add column version int not null default 1 check (version >= 1);

create table mirror.question_versions (
  question_id uuid not null references mirror.reflection_questions(id) on delete cascade,
  version int not null check (version >= 1),
  prompt text not null,
  help text,
  answer_type text not null,
  options jsonb,
  category text not null,
  recorded_at timestamptz not null default now(),
  primary key (question_id, version)
);

insert into mirror.question_versions (question_id, version, prompt, help, answer_type, options, category)
select id, version, prompt, help, answer_type, options, category from mirror.reflection_questions;

alter table mirror.question_versions enable row level security;
revoke all on mirror.question_versions from public, anon, authenticated;
grant all on mirror.question_versions to service_role;
revoke truncate on mirror.question_versions from service_role;

create or replace function mirror.question_versions_append_only() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'TRUNCATE' then raise exception 'Question wording history cannot be emptied.' using errcode = '42501'; end if;
  if tg_op = 'DELETE' and not exists (select 1 from mirror.reflection_questions q where q.id = old.question_id) then
    return old;   -- only together with its question (which cannot go while answers point at it)
  end if;
  raise exception 'Question wording history is never changed; a new version is recorded instead.' using errcode = '42501';
end $$;
create trigger question_versions_append_only before update or delete on mirror.question_versions
  for each row execute function mirror.question_versions_append_only();
create trigger question_versions_no_truncate before truncate on mirror.question_versions
  for each statement execute function mirror.question_versions_append_only();

-- ---------------------------------------------------------------- 3 a wording change raises the version and is recorded
create or replace function mirror.question_version_bump() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'INSERT' then
    new.version := 1;
  elsif (new.prompt, new.help, new.answer_type, new.options, new.category)
        is distinct from (old.prompt, old.help, old.answer_type, old.options, old.category) then
    new.version := old.version + 1;
  else
    new.version := old.version;   -- never set by hand
  end if;
  return new;
end $$;
create trigger reflection_questions_version before insert or update on mirror.reflection_questions
  for each row execute function mirror.question_version_bump();

create or replace function mirror.question_version_record() returns trigger language plpgsql set search_path = mirror as $$
begin
  insert into mirror.question_versions (question_id, version, prompt, help, answer_type, options, category)
  values (new.id, new.version, new.prompt, new.help, new.answer_type, new.options, new.category)
  on conflict (question_id, version) do nothing;
  return null;
end $$;
create trigger reflection_questions_version_record after insert or update on mirror.reflection_questions
  for each row execute function mirror.question_version_record();

-- ---------------------------------------------------------------- 4 each answer keeps the version it was given to
alter table mirror.assessment_responses add column question_version int not null default 1;
alter table mirror.assessment_responses add constraint assessment_responses_question_version_fk
  foreign key (question_id, question_version) references mirror.question_versions (question_id, version) on delete restrict;
alter table mirror.assessment_responses alter column question_version drop default;

create or replace function mirror.response_question_version() returns trigger language plpgsql set search_path = mirror as $$
begin
  select q.version into new.question_version from mirror.reflection_questions q where q.id = new.question_id;
  return new;
end $$;
create trigger assessment_responses_question_version before insert on mirror.assessment_responses
  for each row execute function mirror.response_question_version();

-- ---------------------------------------------------------------- 5 append-only rule also covers the new column and the role
create or replace function mirror.responses_append_only() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from mirror.assessments a where a.id = old.assessment_id) then
      raise exception 'Answers are never deleted one by one; old answers are kept.' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.superseded_at is null and new.superseded_at is not null
     and (new.value, new.state, new.note, new.answered_by, new.answered_by_role, new.answered_at, new.question_id, new.assessment_id, new.question_version)
         is not distinct from (old.value, old.state, old.note, old.answered_by, old.answered_by_role, old.answered_at, old.question_id, old.assessment_id, old.question_version) then
    return new;
  end if;
  raise exception 'Answers are never changed; a new answer is saved instead.' using errcode = '42501';
end $$;

revoke all on function mirror.question_versions_append_only(), mirror.question_version_bump(), mirror.question_version_record(),
  mirror.response_question_version() from public, anon, authenticated;

-- ---------------------------------------------------------------- 6 history and download show the wording that was answered
-- Each history entry adds: version, question (the prompt then), answer_type and options then, reworded (true when the question
-- has changed since). Everything else as in 20261119271000.
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
      'at', x.answered_at, 'current', x.superseded_at is null,
      'version', x.question_version, 'question', qv.prompt, 'answer_type', qv.answer_type, 'options', qv.options,
      'reworded', x.question_version <> q.version) order by x.answered_at desc, x.id desc)
    from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
    join mirror.question_versions qv on qv.question_id = x.question_id and qv.version = x.question_version
    where a.individual_id = v_id and x.question_id = q.id
      and (v_self or x.superseded_at is null)), '[]'::jsonb);
end $$;

-- 'question' is now the wording the person answered; 'question_version' added. Everything else as in 20261119240000.
create or replace function public.mirror_my_export() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); r jsonb;
begin
  r := jsonb_build_object(
    'exported_at', now(),
    'about', 'Your Human Mirror, downloaded from 2nd Chance Housing Inc. It is yours.',
    'me', (select jsonb_build_object('preferred_name', preferred_name, 'legal_name', legal_name, 'birth_year', birth_year, 'email', auth_email,
        'safety_mode', safety_sensitive, 'created_at', created_at) from mirror.individuals where id = v),
    'organizations', public.mirror_my_settings() -> 'organizations',
    'sharing_history', coalesce((select jsonb_agg(jsonb_build_object('organization', o.name, 'topic', c.category, 'access', c.access,
        'given', c.granted_at, 'withdrawn', c.revoked_at) order by c.granted_at)
      from mirror.consents c join mirror.organizations o on o.id = c.organization_id where c.individual_id = v), '[]'::jsonb),
    'answers', coalesce((select jsonb_agg(jsonb_build_object('set', s.title, 'set_key', s.key, 'question', qv.prompt, 'question_key', q.key,
        'question_version', x.question_version,
        'answer', x.value, 'state', x.state, 'note', x.note, 'by', x.answered_by_role, 'at', x.answered_at, 'current', x.superseded_at is null)
        order by s.kind, s.sort, q.sort, x.answered_at)
      from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
      join mirror.question_sets s on s.id = a.set_id join mirror.reflection_questions q on q.id = x.question_id
      join mirror.question_versions qv on qv.question_id = x.question_id and qv.version = x.question_version
      where a.individual_id = v), '[]'::jsonb),
    'daily_number', jsonb_build_object(
      'inputs', mirror.daily_number_inputs(v),
      'household_size', (select household_size from mirror.daily_number_settings where individual_id = v),
      'results', mirror.daily_number(v),
      'saved', coalesce((select jsonb_agg(jsonb_build_object('taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role, 'inputs', s.inputs, 'results', s.results)
          order by s.taken_at) from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb)),
    'who_looked', public.mirror_who_looked());
  perform mirror.audit(v, null, 'self', 'export', 'general', 'individuals', null);
  return r;
end $$;
