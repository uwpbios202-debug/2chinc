-- The Human Mirror T3.1: the assessment engine's data (prompt Part 2: "an extensible assessment engine rather than hardcoding
-- hundreds of questions into individual pages"; D-10 one engine for reflections, dimensions, functional and modules).
--
--  * reflections (8) and dimensions (15) seeded; one question set per reflection seeded (questions themselves: T3.3).
--  * reflection_questions: every question is data, with an answer_type and a privacy category (D-14). Access to a question's answer
--    = mirror.allowed(person, question.category, view/edit): the person always; a coordinator only as the person shares.
--  * assessment_responses are append-only: a new answer supersedes the old row (kept, with its date). Rows are deleted only with the
--    person (D-18 deletion cascades); any other update or delete is refused by a trigger.
--  * Every answer state of the prompt: answered, unknown, not_applicable, prefer_not, needs_help.
--  * Functions: mirror_sets, mirror_set_get, mirror_answer_save, mirror_answers_history. Nothing is required to be answered.

-- ---------------------------------------------------------------- the frame (8 perspectives, 15 dimensions)

create table mirror.reflections (
  key text primary key,
  n int not null unique check (n between 1 and 8),
  title text not null,
  question text not null,
  intro text not null
);

create table mirror.dimensions (
  key text primary key,
  n int not null unique check (n between 1 and 15),
  title text not null,
  intro text not null
);

-- Same text as site/mirror/assets/dimensions.js (keep the two in step).
insert into mirror.reflections (key, n, title, question, intro) values
  ('identity', 1, 'Identity', 'Who am I today?', 'Where I am right now: where I live, what I have, what my days look like, what makes me happy and what I''m proud of.'),
  ('history', 2, 'History', 'Who have I been?', 'Where I came from, what I''ve done, learned and overcome. The past helps explain the journey; it does not decide the future.'),
  ('vision', 3, 'Vision', 'Who do I want to become?', 'The life I want: the home, the work, the learning, the relationships. My vision, in my words; nobody writes it for me.'),
  ('assets', 4, 'Assets', 'What do I have within me?', 'What I''m good at, what I know, what people appreciate about me, and the strengths that helped me get through hard times.'),
  ('needs', 5, 'Needs', 'What must change, and what do I need?', 'What stands between today and the life I want, and what would help most. The bridge from today to tomorrow.'),
  ('function', 6, 'Function', 'What can I do now, and where might I want support?', 'Everyday tasks I handle on my own, and the ones where a little help would make life easier. Never a diagnosis.'),
  ('preferences', 7, 'Preferences', 'How do I want to live?', 'Where, how and with whom I want to live, and the choices that matter to me.'),
  ('contribution', 8, 'Contribution', 'Who can I help, and what can I give back?', 'What I can share or teach, who I''d like to help, and what I''d like to be remembered for. Contribution is more than a paycheck.');

insert into mirror.dimensions (key, n, title, intro) values
  ('housing', 1, 'Shelter, housing and personal environment', 'A safe, stable place to live, and a space that feels like your own.'),
  ('physical_health', 2, 'Physical health and healthcare', 'Your body, your care, and getting to the doctor, dentist and pharmacy.'),
  ('mental_health', 3, 'Mental health and emotional well-being', 'How you feel, what weighs on you, and what helps you feel steady.'),
  ('identity_legal', 4, 'Identity, documentation and legal standing', 'ID, birth certificate, Social Security card and any legal matters that need sorting out.'),
  ('food', 5, 'Food, nutrition and basic necessities', 'Enough good food, and the everyday things a household needs.'),
  ('transportation', 6, 'Transportation and mobility', 'Getting where you need to go: bus, car, rides, or help moving around.'),
  ('technology', 7, 'Technology and digital inclusion', 'A working phone, internet, and the skills to use them for the things that matter.'),
  ('work', 8, 'Education, employment and career development', 'Learning, work, training and the career you''d like to build.'),
  ('finances', 9, 'Financial stability and economic independence', 'Income, bills, savings and what it really costs to live one day: your Daily Number.'),
  ('self_care', 10, 'Personal presentation, hygiene and self-care', 'Clothing, laundry, hygiene and feeling good about how you show up.'),
  ('relationships', 11, 'Social relationships, family and community', 'The people in your life, the people who count on you, and where you belong.'),
  ('life_skills', 12, 'Life skills and independent living', 'Cooking, budgeting, keeping a home, and the skills for running your own life.'),
  ('safety', 13, 'Personal safety, security and protection', 'Feeling safe where you live and with the people around you.'),
  ('development', 14, 'Personal development, interests and fulfillment', 'What you enjoy, what you''re curious about, and what makes life feel full.'),
  ('purpose', 15, 'Purpose, contribution and long-term independence', 'Where you''re headed, what you give back, and standing on your own for the long run.');

-- ---------------------------------------------------------------- questions as data

create table mirror.question_sets (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (key ~ '^[a-z0-9_]+$'),
  kind text not null check (kind in ('reflection', 'dimension', 'functional', 'module')),
  reflection_key text references mirror.reflections(key),
  dimension_key text references mirror.dimensions(key),
  title text not null,
  intro text,
  version int not null default 1,
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into mirror.question_sets (key, kind, reflection_key, title, intro, sort)
select 'reflection_' || r.key, 'reflection', r.key, r.question, r.intro, r.n from mirror.reflections r;

-- Spec name kept: holds the questions of every set, not only reflections.
create table mirror.reflection_questions (
  id uuid primary key default gen_random_uuid(),
  set_id uuid not null references mirror.question_sets(id) on delete restrict,
  key text not null check (key ~ '^[a-z0-9_]+$'),
  prompt text not null,
  help text,
  answer_type text not null check (answer_type in ('text', 'long_text', 'choice', 'multi', 'yes_no', 'number', 'money', 'date', 'rating')),
  options jsonb not null default '[]'::jsonb,         -- [{"value": "...", "label": "..."}] for choice and multi
  category text not null default 'general' check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents')),
  sort int not null default 0,
  active boolean not null default true,                -- retired questions stay (their answers are history)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (set_id, key),
  check (answer_type not in ('choice', 'multi') or jsonb_array_length(options) >= 2)
);
create index reflection_questions_set on mirror.reflection_questions (set_id, sort);

-- ---------------------------------------------------------------- the person's answers

-- One ongoing questionnaire per person per set (save and return any time; never "submitted and locked").
create table mirror.assessments (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  set_id uuid not null references mirror.question_sets(id) on delete restrict,
  set_version int not null,
  organization_id uuid references mirror.organizations(id) on delete set null,   -- set when a coordinator started it with the person
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  conducted_by text,
  unique (individual_id, set_id)
);
create index assessments_person on mirror.assessments (individual_id);

create table mirror.assessment_responses (
  id bigint generated always as identity primary key,
  assessment_id uuid not null references mirror.assessments(id) on delete cascade,
  question_id uuid not null references mirror.reflection_questions(id) on delete restrict,
  value jsonb,                                         -- null unless state = 'answered'
  state text not null check (state in ('answered', 'unknown', 'not_applicable', 'prefer_not', 'needs_help')),
  note text check (note is null or length(note) <= 2000),
  answered_by text not null,
  answered_by_role text not null,                      -- self, coordinator, org_admin
  answered_at timestamptz not null default now(),
  superseded_at timestamptz,
  check ((state = 'answered') = (value is not null))
);
create unique index assessment_responses_current on mirror.assessment_responses (assessment_id, question_id) where superseded_at is null;
create index assessment_responses_question on mirror.assessment_responses (question_id);

-- Append-only: the only change allowed is marking the current row superseded, once. Deletion only together with the person.
create or replace function mirror.responses_append_only() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from mirror.assessments a where a.id = old.assessment_id) then
      raise exception 'Answers are never deleted one by one; old answers are kept.' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.superseded_at is null and new.superseded_at is not null
     and (new.value, new.state, new.note, new.answered_by, new.answered_at, new.question_id, new.assessment_id)
         is not distinct from (old.value, old.state, old.note, old.answered_by, old.answered_at, old.question_id, old.assessment_id) then
    return new;
  end if;
  raise exception 'Answers are never changed; a new answer is saved instead.' using errcode = '42501';
end $$;
create trigger assessment_responses_append_only before update or delete on mirror.assessment_responses
  for each row execute function mirror.responses_append_only();

-- Current answers (the spec's reflection_answers, for every kind of set).
create view mirror.current_answers as
  select a.individual_id, s.key as set_key, s.kind, q.key as question_key, q.category, r.value, r.state, r.note, r.answered_by_role, r.answered_at
  from mirror.assessment_responses r
  join mirror.assessments a on a.id = r.assessment_id
  join mirror.question_sets s on s.id = a.set_id
  join mirror.reflection_questions q on q.id = r.question_id
  where r.superseded_at is null;

-- ---------------------------------------------------------------- quiet permission probe
-- mirror.allowed() unchanged except: p_table = '_probe' skips the audit row. Used to work out what a page may offer (can this
-- person's coordinator edit? how many answers may be counted?) without logging a look that did not happen.
create or replace function mirror.allowed(p_individual uuid, p_category text, p_action text, p_org uuid default null,
  p_table text default null, p_row text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_email text := lower(auth.email());
  v_sensitive boolean := p_category not in ('general', 'safety_flag', 'organization', 'audit');
  v_member boolean := false;
  v_org uuid;
  v_role text;
  v_probe boolean := p_table is not distinct from '_probe';   -- quiet: a permission probe, never logged
  m record;
  p mirror.role_permissions;
begin
  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'Sign-in required.');
  end if;
  if public.autopay_view_as_session() then
    if not v_probe then perform mirror.audit(p_individual, p_org, 'view_as', 'refused', p_category, p_table, p_row, 'view_as'); end if;
    return jsonb_build_object('ok', false, 'reason', 'Not available while viewing as someone else.');
  end if;

  -- the person themself
  if exists (select 1 from mirror.individuals i where i.id = p_individual and i.auth_email = v_email) then
    select * into p from mirror.role_permissions where role = 'self' and category = p_category and action = p_action;
    if found then return jsonb_build_object('ok', true, 'role', 'self'); end if;
    return jsonb_build_object('ok', false, 'role', 'self', 'reason', 'Not allowed.');
  end if;

  -- a member of an organization that works with the person (active link only)
  for m in
    select om.role, om.organization_id
    from mirror.organization_members om
    join mirror.organizations o on o.id = om.organization_id and o.active
    join mirror.organization_individuals oi on oi.organization_id = om.organization_id and oi.individual_id = p_individual and oi.status = 'active'
    where om.auth_email = v_email and om.active and (p_org is null or om.organization_id = p_org)
    order by case om.role when 'org_admin' then 1 when 'coordinator' then 2 else 3 end
  loop
    v_member := true;
    if v_org is null then v_org := m.organization_id; v_role := m.role; end if;
    if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
      if not v_probe then perform mirror.audit(p_individual, m.organization_id, m.role, 'refused', p_category, p_table, p_row, 'no_authenticator'); end if;
      return jsonb_build_object('ok', false, 'role', m.role, 'reason', 'Enter your authenticator code first.');
    end if;
    select * into p from mirror.role_permissions where role = m.role and category = p_category and action = p_action;
    continue when not found;
    if p.needs_consent and not exists (
         select 1 from mirror.consents c
         where c.individual_id = p_individual and c.organization_id = m.organization_id and c.category = p_category
           and c.revoked_at is null and (c.expires_on is null or c.expires_on >= current_date)
           and (p_action = 'view' or c.access = 'edit')) then
      continue;
    end if;
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit(p_individual, m.organization_id, m.role, p_action, p_category, p_table, p_row, null); end if;
    end if;
    return jsonb_build_object('ok', true, 'role', m.role, 'organization_id', m.organization_id);
  end loop;

  if v_member then
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit(p_individual, v_org, v_role, 'refused', p_category, p_table, p_row, 'no_consent'); end if;
    end if;
    return jsonb_build_object('ok', false, 'reason', 'The person has not shared this with your organization.');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'Not allowed.');
end $$;

create or replace function mirror.may(p_individual uuid, p_category text, p_action text) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce((mirror.allowed(p_individual, p_category, p_action, null, '_probe', null) ->> 'ok')::boolean, false);
$$;

-- ---------------------------------------------------------------- helpers

-- Whose Mirror: p_individual, or the caller's own when null.
create or replace function mirror.target_individual(p_individual uuid) returns uuid
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid;
begin
  if p_individual is not null then return p_individual; end if;
  select id into v from mirror.individuals where auth_email = lower(auth.email());
  if v is null then raise exception 'There is no Mirror for this sign-in.' using errcode = '42501'; end if;
  return v;
end $$;

-- Checks a value against the question's answer type and returns it in a normal form (or raises in plain words).
create or replace function mirror.clean_answer(q mirror.reflection_questions, v jsonb) returns jsonb
language plpgsql stable set search_path = mirror, public as $$
declare t text; n numeric; d date; allowed text[];
begin
  if v is null or v = 'null'::jsonb then raise exception 'Nothing to save. Choose "I don''t know" or skip instead.' using errcode = '22023'; end if;
  allowed := array(select x ->> 'value' from jsonb_array_elements(q.options) x);
  case q.answer_type
    when 'text', 'long_text' then
      if jsonb_typeof(v) <> 'string' then raise exception 'Expected words.' using errcode = '22023'; end if;
      t := btrim(v #>> '{}');
      if t = '' then raise exception 'Nothing to save. Choose "I don''t know" or skip instead.' using errcode = '22023'; end if;
      if length(t) > (case when q.answer_type = 'text' then 500 else 5000 end) then raise exception 'That answer is too long. Please shorten it.' using errcode = '22023'; end if;
      return to_jsonb(t);
    when 'choice' then
      if jsonb_typeof(v) <> 'string' or not (v #>> '{}') = any (allowed) then raise exception 'Choose one of the answers shown.' using errcode = '22023'; end if;
      return v;
    when 'multi' then
      if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0
         or exists (select 1 from jsonb_array_elements(v) e where jsonb_typeof(e) <> 'string' or not (e #>> '{}') = any (allowed)) then
        raise exception 'Choose one or more of the answers shown.' using errcode = '22023';
      end if;
      return (select jsonb_agg(distinct e) from jsonb_array_elements(v) e);
    when 'yes_no' then
      if jsonb_typeof(v) <> 'boolean' then raise exception 'Answer yes or no.' using errcode = '22023'; end if;
      return v;
    when 'number', 'money' then
      begin n := (v #>> '{}')::numeric; exception when others then raise exception 'Enter a number, for example 12 or 12.50.' using errcode = '22023'; end;
      if q.answer_type = 'money' then
        if n < 0 or n > 10000000 then raise exception 'Enter an amount of zero or more.' using errcode = '22023'; end if;
        return to_jsonb(round(n, 2));
      end if;
      return to_jsonb(n);
    when 'date' then
      begin d := (v #>> '{}')::date; exception when others then raise exception 'Enter a date.' using errcode = '22023'; end;
      if d < date '1900-01-01' or d > current_date + 36500 then raise exception 'That date looks wrong.' using errcode = '22023'; end if;
      return to_jsonb(d::text);
    when 'rating' then
      begin n := (v #>> '{}')::numeric; exception when others then n := null; end;
      if n is null or n not in (1, 2, 3, 4, 5) then raise exception 'Choose 1 to 5.' using errcode = '22023'; end if;
      return to_jsonb(n::int);
  end case;
end $$;

-- ---------------------------------------------------------------- functions for pages

-- Sets of one kind (or all) with how many questions are answered, counting only what the caller may see.
create or replace function public.mirror_sets(p_kind text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_ok text[] := '{}';
  c text;
begin
  foreach c in array array['general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents'] loop
    if mirror.may(v_id, c, 'view') then v_ok := v_ok || c; end if;   -- counting only: not a look at answers
  end loop;
  if cardinality(v_ok) = 0 then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'key', s.key, 'kind', s.kind, 'title', s.title, 'intro', s.intro, 'reflection', s.reflection_key, 'dimension', s.dimension_key,
      'questions', (select count(*) from mirror.reflection_questions q where q.set_id = s.id and q.active and q.category = any (v_ok)),
      'answered', (select count(*) from mirror.current_answers ca join mirror.reflection_questions q on q.key = ca.question_key and q.set_id = s.id
                   where ca.individual_id = v_id and ca.set_key = s.key and q.active and q.category = any (v_ok)),
      'updated_at', (select a.updated_at from mirror.assessments a where a.individual_id = v_id and a.set_id = s.id))
    order by s.kind, s.sort, s.key)
    from mirror.question_sets s where s.active and (p_kind is null or s.kind = p_kind)), '[]'::jsonb);
end $$;

-- One set: its questions and the current answers the caller may see. Questions in a category the caller may not see come back
-- with "hidden": true and no answer (coordinators see that something is private, never what).
create or replace function public.mirror_set_get(p_set_key text, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
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
        'category', q.category, 'private', q.category <> 'general',
        'hidden', not (q.category = any (v_ok)),
        'can_edit', q.category = any (v_edit),
        'answer', case when q.category = any (v_ok) then (
            select jsonb_build_object('value', ca.value, 'state', ca.state, 'note', ca.note, 'by', ca.answered_by_role, 'at', ca.answered_at)
            from mirror.current_answers ca where ca.individual_id = v_id and ca.set_key = s.key and ca.question_key = q.key) end)
      order by q.sort, q.key)
      from mirror.reflection_questions q where q.set_id = s.id and q.active), '[]'::jsonb));
end $$;

-- Save one answer. p_state: answered (with p_value) | unknown | not_applicable | prefer_not | needs_help.
-- Saving the same answer again changes nothing. Returns the set's counts.
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

  return jsonb_build_object('saved', true,
    'answered', (select count(*) from mirror.current_answers ca where ca.individual_id = v_id and ca.set_key = s.key),
    'questions', (select count(*) from mirror.reflection_questions x where x.set_id = s.id and x.active));
end $$;

-- Every answer ever given to one question, newest first (the person can see how they've changed).
create or replace function public.mirror_answers_history(p_set_key text, p_question_key text, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  q mirror.reflection_questions;
  r jsonb;
begin
  select qq.* into q from mirror.reflection_questions qq join mirror.question_sets s on s.id = qq.set_id where s.key = p_set_key and qq.key = p_question_key;
  if not found then raise exception 'That question is not available.' using errcode = 'P0002'; end if;
  r := mirror.allowed(v_id, q.category, 'view', null, 'assessment_responses', q.id::text);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('value', x.value, 'state', x.state, 'note', x.note, 'by', x.answered_by_role,
      'at', x.answered_at, 'current', x.superseded_at is null) order by x.answered_at desc, x.id desc)
    from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
    where a.individual_id = v_id and x.question_id = q.id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- triggers, row security, grants

create trigger question_sets_touch before update on mirror.question_sets for each row execute function mirror.touch();
create trigger reflection_questions_touch before update on mirror.reflection_questions for each row execute function mirror.touch();

alter table mirror.reflections enable row level security;
alter table mirror.dimensions enable row level security;
alter table mirror.question_sets enable row level security;
alter table mirror.reflection_questions enable row level security;
alter table mirror.assessments enable row level security;
alter table mirror.assessment_responses enable row level security;

revoke all on mirror.reflections, mirror.dimensions, mirror.question_sets, mirror.reflection_questions, mirror.assessments,
  mirror.assessment_responses, mirror.current_answers from public, anon, authenticated;
grant all on mirror.reflections, mirror.dimensions, mirror.question_sets, mirror.reflection_questions, mirror.assessments,
  mirror.assessment_responses, mirror.current_answers to service_role;
grant usage on all sequences in schema mirror to service_role;

revoke all on function mirror.may(uuid, text, text) from public, anon, authenticated;
grant execute on function mirror.may(uuid, text, text) to service_role;
revoke all on function mirror.target_individual(uuid), mirror.clean_answer(mirror.reflection_questions, jsonb), mirror.responses_append_only()
  from public, anon, authenticated;
grant execute on function mirror.target_individual(uuid), mirror.clean_answer(mirror.reflection_questions, jsonb) to service_role;

revoke all on function public.mirror_sets(text, uuid), public.mirror_set_get(text, uuid),
  public.mirror_answer_save(text, text, jsonb, text, text, uuid), public.mirror_answers_history(text, text, uuid) from public, anon;
grant execute on function public.mirror_sets(text, uuid), public.mirror_set_get(text, uuid),
  public.mirror_answer_save(text, text, jsonb, text, text, uuid), public.mirror_answers_history(text, text, uuid) to authenticated, service_role;
