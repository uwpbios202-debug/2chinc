-- The Human Mirror T1.6: the conversation guide saves (Stephen 11/13/2026 "build it"; D-21, D-14, D-20, D-27; DEFAULTS in D-29).
--
-- What it does
--   * The person answers the open questions on their own My Mirror (speaking or typing). Answers are saved as they go and are
--     seen by the PERSON ONLY: no organization reads the raw answers.
--   * "What I heard" (phrase matching in the browser, D-21 option 1) is saved as findings, each with the person's own words. The person
--     removes what is wrong, ticks what to share and picks the ONE organization it goes to. Ticking one finding is the person's consent
--     for that one item to that organization; it does not open the whole topic (D-14 stays as it is for everything else).
--   * The organization's coordinators see only the ticked findings of conversations shared with them; every look at a private one is
--     logged for the person's "who looked" (mirror.audit). The number of unshared findings is shown, never their content.
--   * A finding becomes a need (Phase 6 mirror.needs) through public.mirror_need_save, so the needs rules apply unchanged
--     (topic from the area of life; a coordinator needs the person's "see and change" for that topic).
--   * Referrals are made with the existing public.chpms_referral_save (office staff, field staff, Navigators) and linked here.
--   * Missed phrases: coordinators add plain words (no patterns) for their own organization; the person's page uses the phrases of
--     the organizations they work with. A phrase can only point at a known meaning (mirror.listen_keys).
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only; browsers use the functions below.

-- ---------------------------------------------------------------- what a finding can mean
create table mirror.listen_keys (
  kind text not null check (kind in ('urgent', 'help', 'other', 'pop')),
  key text not null check (length(key) between 1 and 60),
  label text not null,
  dimension_key text references mirror.dimensions(key) on delete restrict,   -- null: describes the person, never a need
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial')),
  primary key (kind, key)
);

insert into mirror.listen_keys (kind, key, label, dimension_key, category) values
  ('urgent', 'tonight', 'No safe place to sleep tonight', 'housing', 'general'),
  ('urgent', 'harm', 'Thoughts of hurting yourself', 'mental_health', 'mental_health'),
  ('urgent', 'violence', 'Not safe at home', 'safety', 'safety'),
  ('help', 'Eviction prevention', 'Eviction prevention', 'housing', 'general'),
  ('help', 'Emergency rental assistance', 'Emergency rental assistance', 'housing', 'general'),
  ('help', 'Monthly rental assistance', 'Monthly rental assistance', 'housing', 'general'),
  ('help', 'Security deposit assistance', 'Security deposit assistance', 'housing', 'general'),
  ('help', 'First month''s rent', 'First month''s rent', 'housing', 'general'),
  ('help', 'Utility assistance', 'Utility assistance', 'housing', 'general'),
  ('help', 'Moving expenses', 'Moving expenses', 'housing', 'general'),
  ('help', 'Furniture and household items', 'Furniture and household items', 'housing', 'general'),
  ('help', 'Rapid rehousing', 'Rapid rehousing', 'housing', 'general'),
  ('help', 'Housing vouchers', 'Housing vouchers', 'housing', 'general'),
  ('help', 'Supportive housing', 'Supportive housing', 'housing', 'general'),
  ('help', 'Permanent housing', 'Permanent housing', 'housing', 'general'),
  ('help', 'Transitional housing', 'Transitional housing', 'housing', 'general'),
  ('help', 'Housing navigation', 'Housing navigation', 'housing', 'general'),
  ('help', 'Landlord mediation', 'Landlord mediation', 'housing', 'general'),
  ('help', 'Case management', 'Case management', 'life_skills', 'general'),
  ('help', 'Financial counseling', 'Financial counseling', 'finances', 'financial'),
  ('help', 'Benefits enrollment', 'Benefits enrollment', 'finances', 'financial'),
  ('other', 'food', 'Food', 'food', 'general'),
  ('other', 'transport', 'Getting around (transportation)', 'transportation', 'general'),
  ('other', 'work', 'Work and job training', 'work', 'general'),
  ('other', 'childcare', 'Child care', 'relationships', 'general'),
  ('other', 'phone', 'Phone and internet', 'technology', 'general'),
  ('other', 'health', 'Health care', 'physical_health', 'health'),
  ('other', 'mental', 'Mental health and stress', 'mental_health', 'mental_health'),
  ('other', 'recovery', 'Recovery support', 'mental_health', 'mental_health'),
  ('other', 'id', 'ID and documents', 'identity_legal', 'legal'),
  ('other', 'legal', 'Legal matters', 'identity_legal', 'legal'),
  ('other', 'immigration', 'Immigration', 'identity_legal', 'immigration'),
  ('pop', 'Veterans', 'Veterans', null, 'general'),
  ('pop', 'Seniors', 'Seniors', null, 'general'),
  ('pop', 'Fixed income (SS/SSI/SSDI/VA)', 'Fixed income (SS/SSI/SSDI/VA)', null, 'general'),
  ('pop', 'Families with children', 'Families with children', null, 'general'),
  ('pop', 'Experiencing homelessness', 'Experiencing homelessness', null, 'general'),
  ('pop', 'At risk of eviction', 'At risk of eviction', null, 'general'),
  ('pop', 'Disabilities', 'Disabilities', null, 'general'),
  ('pop', 'Returning citizens', 'Returning citizens', null, 'legal'),
  ('pop', 'Low-income working', 'Low-income working', null, 'general'),
  ('pop', 'No current income', 'No current income', null, 'general');

-- ---------------------------------------------------------------- conversations, answers, findings, referrals, phrases
create table mirror.conversations (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  organization_id uuid references mirror.organizations(id) on delete set null,   -- the one organization it is shared with
  status text not null default 'open' check (status in ('open', 'kept', 'shared')),   -- open = answering; kept = saved for myself; shared
  shared_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'shared') = (organization_id is not null and shared_at is not null))
);
create unique index conversations_one_open on mirror.conversations (individual_id) where status = 'open';
create index conversations_org on mirror.conversations (organization_id, status);
create trigger conversations_touch before update on mirror.conversations for each row execute function mirror.touch();

create table mirror.conversation_answers (
  conversation_id uuid not null references mirror.conversations(id) on delete cascade,
  question_id text not null check (question_id in ('home', 'hardest', 'money', 'people', 'day', 'safety', 'past', 'future')),
  answer text not null check (length(answer) between 1 and 4000),
  updated_at timestamptz not null default now(),
  primary key (conversation_id, question_id)
);

create table mirror.conversation_findings (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references mirror.conversations(id) on delete cascade,
  kind text not null,
  key text not null,
  quotes jsonb not null default '[]'::jsonb check (jsonb_typeof(quotes) = 'array' and jsonb_array_length(quotes) <= 3),
  shared boolean not null default false,
  need_id uuid references mirror.needs(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (kind, key) references mirror.listen_keys(kind, key),
  unique (conversation_id, kind, key)
);
create trigger conversation_findings_touch before update on mirror.conversation_findings for each row execute function mirror.touch();

create table mirror.conversation_referrals (
  id bigint generated always as identity primary key,
  finding_id uuid not null references mirror.conversation_findings(id) on delete cascade,
  chpms_referral_id uuid not null,
  organization_id uuid references mirror.organizations(id) on delete set null,
  org_name text,
  program_name text,
  made_by_email text not null,
  made_by_role text not null,
  at timestamptz not null default now(),
  unique (finding_id, chpms_referral_id)
);

create table mirror.listen_phrases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references mirror.organizations(id) on delete cascade,
  phrase text not null check (length(phrase) between 3 and 60 and phrase ~* '^[a-z0-9][a-z0-9'' -]*[a-z0-9]$'),
  kind text not null,
  key text not null,
  added_by text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  retired_at timestamptz,
  retired_by text,
  foreign key (kind, key) references mirror.listen_keys(kind, key)
);
create unique index listen_phrases_one on mirror.listen_phrases (organization_id, lower(phrase), kind, key) where active;

-- ---------------------------------------------------------------- helpers
-- A coordinator or org admin of an active organization, with a fresh session and the authenticator. Returns the role.
create or replace function mirror.conv_member(p_org uuid) returns text
language plpgsql stable security definer set search_path = mirror, public as $$
declare v_role text;
begin
  if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  select om.role into v_role from mirror.organization_members om join mirror.organizations o on o.id = om.organization_id and o.active
   where om.organization_id = p_org and om.auth_email = lower(auth.email()) and om.active and om.role in ('coordinator', 'org_admin');
  if v_role is null then raise exception 'You are not a coordinator of this organization.' using errcode = '42501'; end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then raise exception 'Enter your authenticator code first.' using errcode = '42501'; end if;
  return v_role;
end $$;

-- A coordinator's access to a person through one organization (quiet probe: the gate, never logged here).
create or replace function mirror.conv_org_access(p_individual uuid, p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare g jsonb;
begin
  if p_org is null then raise exception 'Choose your organization.' using errcode = '22023'; end if;
  perform mirror.conv_member(p_org);
  g := mirror.allowed(p_individual, 'general', 'view', p_org, '_probe', null);
  if not (g ->> 'ok')::boolean then raise exception '%', g ->> 'reason' using errcode = '42501'; end if;
  if (g ->> 'role') = 'self' then raise exception 'Open your own conversation on My Mirror.' using errcode = '42501'; end if;
  return g;
end $$;

-- One finding as a page sees it. The need is shown only when the caller may see its topic (quiet probe).
create or replace function mirror.finding_json(f mirror.conversation_findings, p_individual uuid) returns jsonb
language sql security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', f.id, 'kind', f.kind, 'key', f.key, 'label', k.label, 'category', k.category,
    'private', k.category <> 'general', 'dimension', k.dimension_key, 'quotes', f.quotes, 'shared', f.shared,
    'need', (select jsonb_build_object('id', n.id, 'status', n.status, 'title', n.title) from mirror.needs n
              where n.id = f.need_id and mirror.may(p_individual, n.category, 'view')),
    'referrals', coalesce((select jsonb_agg(jsonb_build_object('org_name', r.org_name, 'program_name', r.program_name, 'at', r.at, 'by_role', r.made_by_role)
                 order by r.at) from mirror.conversation_referrals r where r.finding_id = f.id), '[]'::jsonb))
  from mirror.listen_keys k where k.kind = f.kind and k.key = f.key;
$$;

-- ---------------------------------------------------------------- the person's own side
create or replace function public.mirror_conversation_mine() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return jsonb_build_object(
    'conversations', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'organization_id', c.organization_id,
        'organization', (select o.name from mirror.organizations o where o.id = c.organization_id), 'shared_at', c.shared_at,
        'created_at', c.created_at, 'updated_at', c.updated_at,
        'answers', coalesce((select jsonb_object_agg(a.question_id, a.answer) from mirror.conversation_answers a where a.conversation_id = c.id), '{}'::jsonb),
        'findings', coalesce((select jsonb_agg(mirror.finding_json(f, v) order by f.created_at, f.kind, f.key)
                    from mirror.conversation_findings f where f.conversation_id = c.id), '[]'::jsonb))
      order by c.created_at desc) from (select * from mirror.conversations where individual_id = v order by created_at desc limit 20) c), '[]'::jsonb),
    'organizations', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name) order by o.name)
      from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
      where oi.individual_id = v and oi.status = 'active'), '[]'::jsonb),
    'phrases', coalesce((select jsonb_agg(distinct jsonb_build_object('phrase', p.phrase, 'kind', p.kind, 'key', p.key))
      from mirror.listen_phrases p join mirror.organization_individuals oi on oi.organization_id = p.organization_id and oi.status = 'active'
      join mirror.organizations o on o.id = p.organization_id and o.active
      where oi.individual_id = v and p.active), '[]'::jsonb));
end $$;

create or replace function public.mirror_conversation_start() returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); c uuid;
begin
  select id into c from mirror.conversations where individual_id = v and status = 'open';
  if c is null then insert into mirror.conversations (individual_id) values (v) returning id into c; end if;
  return c;
end $$;

create or replace function public.mirror_conversation_answer_save(p_conversation uuid, p_question text, p_answer text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); c mirror.conversations; v_a text := btrim(coalesce(p_answer, ''));
begin
  select * into c from mirror.conversations where id = p_conversation and individual_id = v;
  if not found then raise exception 'That conversation is not available.' using errcode = 'P0002'; end if;
  if c.status <> 'open' then raise exception 'This conversation is finished. Start a new one to answer again.' using errcode = '22023'; end if;
  if coalesce(p_question, '') not in ('home', 'hardest', 'money', 'people', 'day', 'safety', 'past', 'future') then
    raise exception 'Unknown question.' using errcode = '22023';
  end if;
  if length(v_a) > 4000 then raise exception 'Please keep each answer to 4,000 letters.' using errcode = '22023'; end if;
  if v_a = '' then
    delete from mirror.conversation_answers where conversation_id = c.id and question_id = p_question;
  else
    insert into mirror.conversation_answers (conversation_id, question_id, answer) values (c.id, p_question, v_a)
    on conflict (conversation_id, question_id) do update set answer = excluded.answer, updated_at = now();
  end if;
  update mirror.conversations set updated_at = now() where id = c.id;
end $$;

-- Saves "what I heard" and the person's choices, and closes the answering. p_org null = keep it for myself (status kept, nothing shared).
-- p_findings: [{kind, key, quotes: [{q, words}], shared}]; a finding left out is removed unless it already became a need or a referral.
create or replace function public.mirror_conversation_share(p_conversation uuid, p_org uuid, p_findings jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v uuid := mirror.me();
  c mirror.conversations;
  x jsonb;
  q jsonb;
  v_quotes jsonb;
  v_keep text[] := '{}';
  v_shared int := 0;
begin
  select * into c from mirror.conversations where id = p_conversation and individual_id = v;
  if not found then raise exception 'That conversation is not available.' using errcode = 'P0002'; end if;
  if jsonb_typeof(coalesce(p_findings, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_findings) > 80 then
    raise exception 'Nothing to save.' using errcode = '22023';
  end if;
  if p_org is not null and not exists (select 1 from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
                                        where oi.individual_id = v and oi.organization_id = p_org and oi.status = 'active') then
    raise exception 'You are not working with that organization.' using errcode = '42501';
  end if;
  for x in select * from jsonb_array_elements(p_findings) loop
    if not exists (select 1 from mirror.listen_keys k where k.kind = x ->> 'kind' and k.key = x ->> 'key') then
      raise exception 'Unknown finding.' using errcode = '22023';
    end if;
    v_quotes := '[]'::jsonb;
    for q in select * from jsonb_array_elements(case when jsonb_typeof(x -> 'quotes') = 'array' then x -> 'quotes' else '[]'::jsonb end) loop
      exit when jsonb_array_length(v_quotes) >= 3;
      if (q ->> 'q') in ('home', 'hardest', 'money', 'people', 'day', 'safety', 'past', 'future') and length(btrim(coalesce(q ->> 'words', ''))) between 1 and 300 then
        v_quotes := v_quotes || jsonb_build_object('q', q ->> 'q', 'words', btrim(q ->> 'words'));
      end if;
    end loop;
    insert into mirror.conversation_findings (conversation_id, kind, key, quotes, shared)
    values (c.id, x ->> 'kind', x ->> 'key', v_quotes, coalesce((x ->> 'shared')::boolean, false))
    on conflict (conversation_id, kind, key) do update set quotes = excluded.quotes, shared = excluded.shared;
    v_keep := v_keep || ((x ->> 'kind') || ':' || (x ->> 'key'));
    if coalesce((x ->> 'shared')::boolean, false) then v_shared := v_shared + 1; end if;
  end loop;
  -- removed by the person: gone, unless it already became a need or a referral (then kept, not shared)
  delete from mirror.conversation_findings f where f.conversation_id = c.id and not ((f.kind || ':' || f.key) = any (v_keep))
    and f.need_id is null and not exists (select 1 from mirror.conversation_referrals r where r.finding_id = f.id);
  update mirror.conversation_findings f set shared = false where f.conversation_id = c.id and not ((f.kind || ':' || f.key) = any (v_keep));
  if p_org is null then
    update mirror.conversation_findings set shared = false where conversation_id = c.id;
    if c.status = 'shared' then
      perform mirror.audit(v, c.organization_id, 'self', 'unshare', 'general', 'conversations', c.id::text, 'conversation taken back');
    end if;
    update mirror.conversations set status = 'kept', organization_id = null, shared_at = null where id = c.id;
  else
    update mirror.conversations set status = 'shared', organization_id = p_org, shared_at = now() where id = c.id;
    perform mirror.audit(v, p_org, 'self', 'share', 'general', 'conversations', c.id::text, v_shared || ' item(s) shared from a conversation');
  end if;
  return (select jsonb_agg(mirror.finding_json(f, v) order by f.created_at, f.kind, f.key) from mirror.conversation_findings f where f.conversation_id = c.id);
end $$;

-- A conversation not shared now, with nothing on the needs list and no referral, can be thrown away by the person.
create or replace function public.mirror_conversation_discard(p_conversation uuid) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); c mirror.conversations;
begin
  select * into c from mirror.conversations where id = p_conversation and individual_id = v;
  if not found then raise exception 'That conversation is not available.' using errcode = 'P0002'; end if;
  if c.status = 'shared' then raise exception 'Take it back from the organization first.' using errcode = '22023'; end if;
  if exists (select 1 from mirror.conversation_findings f join mirror.conversation_referrals r on r.finding_id = f.id where f.conversation_id = c.id) then
    raise exception 'A referral was made from this conversation, so it is kept.' using errcode = '22023';
  end if;
  if exists (select 1 from mirror.conversation_findings f where f.conversation_id = c.id and f.need_id is not null) then
    raise exception 'Something from this conversation is on your needs list, so it is kept.' using errcode = '22023';
  end if;
  delete from mirror.conversations where id = c.id;
end $$;

-- ---------------------------------------------------------------- the coordinator's side
create or replace function public.mirror_conversations_shared(p_individual uuid, p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare g jsonb := mirror.conv_org_access(p_individual, p_org); v_role text := g ->> 'role'; f record; r jsonb;
begin
  r := jsonb_build_object(
    'can_refer', coalesce(public.chpms_role(), 'navigator_preview') <> 'navigator_preview',
    'conversations', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'shared_at', c.shared_at,
        'findings', coalesce((select jsonb_agg(mirror.finding_json(x, p_individual) order by x.created_at, x.kind, x.key)
                    from mirror.conversation_findings x where x.conversation_id = c.id and x.shared), '[]'::jsonb),
        'not_shared', (select count(*) from mirror.conversation_findings x where x.conversation_id = c.id and not x.shared))
      order by c.shared_at desc)
      from mirror.conversations c where c.individual_id = p_individual and c.status = 'shared' and c.organization_id = p_org), '[]'::jsonb),
    'phrases', public.mirror_listen_phrases(p_org));
  -- every private item shown is a look the person can see in "who looked"
  for f in select x.id, k.category from mirror.conversation_findings x join mirror.conversations c on c.id = x.conversation_id
            join mirror.listen_keys k on k.kind = x.kind and k.key = x.key
           where c.individual_id = p_individual and c.status = 'shared' and c.organization_id = p_org and x.shared and k.category <> 'general' loop
    perform mirror.audit(p_individual, p_org, v_role, 'view', f.category, 'conversation_findings', f.id::text, 'shared by the person in a conversation');
  end loop;
  return r;
end $$;

-- A finding the coordinator may act on: shared with their organization, in a conversation still shared with it.
create or replace function mirror.conv_finding_for_org(p_finding uuid, p_org uuid) returns mirror.conversation_findings
language plpgsql security definer set search_path = mirror, public as $$
declare f mirror.conversation_findings; c mirror.conversations;
begin
  select * into f from mirror.conversation_findings where id = p_finding;
  if not found then raise exception 'That item is not available.' using errcode = 'P0002'; end if;
  select * into c from mirror.conversations where id = f.conversation_id;
  if c.status <> 'shared' or c.organization_id is distinct from p_org or not f.shared then
    raise exception 'That item is not shared with your organization.' using errcode = '42501';
  end if;
  perform mirror.conv_org_access(c.individual_id, p_org);
  return f;
end $$;

-- Puts a finding on the needs list (Phase 6), with the person's words as the details. The person, or a coordinator of the
-- organization it was shared with; mirror_need_save applies the needs rules (a coordinator needs "see and change" for the topic).
create or replace function public.mirror_conversation_need(p_finding uuid, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  f mirror.conversation_findings;
  c mirror.conversations;
  k mirror.listen_keys;
  v_self boolean;
  v_need jsonb;
  v_detail text;
begin
  select * into f from mirror.conversation_findings where id = p_finding;
  if not found then raise exception 'That item is not available.' using errcode = 'P0002'; end if;
  select * into c from mirror.conversations where id = f.conversation_id;
  v_self := exists (select 1 from mirror.individuals i where i.id = c.individual_id and i.auth_email = lower(auth.email()));
  if v_self then perform mirror.me(); else f := mirror.conv_finding_for_org(p_finding, p_org); end if;
  select * into k from mirror.listen_keys where kind = f.kind and key = f.key;
  if k.dimension_key is null then raise exception 'This describes the person; it is not a need.' using errcode = '22023'; end if;
  if f.need_id is not null and exists (select 1 from mirror.needs n where n.id = f.need_id) then
    raise exception 'This is already on the needs list.' using errcode = '22023';
  end if;
  select left('From a conversation on ' || to_char(coalesce(c.shared_at, c.created_at) at time zone 'America/Chicago', 'MM/DD/YYYY')
    || coalesce(', in their words: ' || string_agg('"' || (q ->> 'words') || '"', ' '), '.'), 2000)
    into v_detail from jsonb_array_elements(f.quotes) q;
  v_need := public.mirror_need_save(null, k.dimension_key, k.label, v_detail, case when f.kind = 'urgent' then 'urgent' else 'soon' end, c.individual_id);
  update mirror.conversation_findings set need_id = (v_need ->> 'id')::uuid where id = f.id;
  return v_need;
end $$;

-- Links a referral the caller just made with chpms_referral_save to the finding it answers.
create or replace function public.mirror_conversation_referral_log(p_finding uuid, p_org uuid, p_referral uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare f mirror.conversation_findings; g jsonb; rf record; v_ind uuid;
begin
  f := mirror.conv_finding_for_org(p_finding, p_org);
  select c.individual_id into v_ind from mirror.conversations c where c.id = f.conversation_id;
  g := mirror.conv_org_access(v_ind, p_org);
  select r.id, r.org_name, r.program_name into rf from public.chpms_referrals r
   where r.id = p_referral and lower(r.made_by_email) = lower(auth.email());
  if rf.id is null then raise exception 'That referral was not found.' using errcode = 'P0002'; end if;
  insert into mirror.conversation_referrals (finding_id, chpms_referral_id, organization_id, org_name, program_name, made_by_email, made_by_role)
  values (f.id, rf.id, p_org, rf.org_name, rf.program_name, lower(auth.email()), g ->> 'role')
  on conflict (finding_id, chpms_referral_id) do nothing;
  return mirror.finding_json(f, v_ind);
end $$;

-- ---------------------------------------------------------------- missed phrases (per organization)
create or replace function public.mirror_listen_phrases(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
begin
  perform mirror.conv_member(p_org);
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'phrase', p.phrase, 'kind', p.kind, 'key', p.key, 'label', k.label,
      'added_by', p.added_by, 'created_at', p.created_at) order by lower(p.phrase))
    from mirror.listen_phrases p join mirror.listen_keys k on k.kind = p.kind and k.key = p.key
    where p.organization_id = p_org and p.active), '[]'::jsonb);
end $$;

create or replace function public.mirror_listen_phrase_add(p_org uuid, p_phrase text, p_kind text, p_key text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_p text := lower(regexp_replace(btrim(coalesce(p_phrase, '')), '\s+', ' ', 'g'));
begin
  perform mirror.conv_member(p_org);
  if length(v_p) < 3 or length(v_p) > 60 or v_p !~ '^[a-z0-9][a-z0-9'' -]*[a-z0-9]$' then
    raise exception 'Use 3 to 60 letters, numbers, spaces, apostrophes or dashes.' using errcode = '22023';
  end if;
  if not exists (select 1 from mirror.listen_keys k where k.kind = p_kind and k.key = p_key) then
    raise exception 'Choose what the words mean.' using errcode = '22023';
  end if;
  if (select count(*) from mirror.listen_phrases where organization_id = p_org and active) >= 500 then
    raise exception 'Your organization has 500 phrases; retire some first.' using errcode = '22023';
  end if;
  insert into mirror.listen_phrases (organization_id, phrase, kind, key, added_by) values (p_org, v_p, p_kind, p_key, lower(auth.email()))
  on conflict do nothing;
  return public.mirror_listen_phrases(p_org);
end $$;

create or replace function public.mirror_listen_phrase_retire(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_org uuid;
begin
  select organization_id into v_org from mirror.listen_phrases where id = p_id and active;
  if v_org is null then raise exception 'That phrase is not available.' using errcode = 'P0002'; end if;
  perform mirror.conv_member(v_org);
  update mirror.listen_phrases set active = false, retired_at = now(), retired_by = lower(auth.email()) where id = p_id;
  return public.mirror_listen_phrases(v_org);
end $$;

-- ---------------------------------------------------------------- the person's download
create or replace function public.mirror_my_export_conversations() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('started', c.created_at, 'status', c.status, 'shared_with', o.name, 'shared_at', c.shared_at,
      'answers', coalesce((select jsonb_object_agg(a.question_id, a.answer) from mirror.conversation_answers a where a.conversation_id = c.id), '{}'::jsonb),
      'what_was_heard', coalesce((select jsonb_agg(jsonb_build_object('what', k.label, 'your_words', f.quotes, 'shared', f.shared,
          'referrals', (select jsonb_agg(jsonb_build_object('to', r.org_name, 'program', r.program_name, 'at', r.at)) from mirror.conversation_referrals r where r.finding_id = f.id))
          order by f.created_at) from mirror.conversation_findings f join mirror.listen_keys k on k.kind = f.kind and k.key = f.key
          where f.conversation_id = c.id), '[]'::jsonb))
      order by c.created_at)
    from mirror.conversations c left join mirror.organizations o on o.id = c.organization_id where c.individual_id = v), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- row security and grants
alter table mirror.listen_keys enable row level security;
alter table mirror.conversations enable row level security;
alter table mirror.conversation_answers enable row level security;
alter table mirror.conversation_findings enable row level security;
alter table mirror.conversation_referrals enable row level security;
alter table mirror.listen_phrases enable row level security;
revoke all on mirror.listen_keys, mirror.conversations, mirror.conversation_answers, mirror.conversation_findings,
  mirror.conversation_referrals, mirror.listen_phrases from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.listen_keys, mirror.conversations, mirror.conversation_answers, mirror.conversation_findings,
  mirror.conversation_referrals, mirror.listen_phrases to service_role;
grant usage on all sequences in schema mirror to service_role;

revoke all on function mirror.conv_member(uuid), mirror.conv_org_access(uuid, uuid), mirror.finding_json(mirror.conversation_findings, uuid),
  mirror.conv_finding_for_org(uuid, uuid) from public, anon, authenticated;
grant execute on function mirror.conv_member(uuid), mirror.conv_org_access(uuid, uuid), mirror.finding_json(mirror.conversation_findings, uuid),
  mirror.conv_finding_for_org(uuid, uuid) to service_role;

revoke all on function public.mirror_conversation_mine(), public.mirror_conversation_start(), public.mirror_conversation_answer_save(uuid, text, text),
  public.mirror_conversation_share(uuid, uuid, jsonb), public.mirror_conversation_discard(uuid), public.mirror_conversations_shared(uuid, uuid),
  public.mirror_conversation_need(uuid, uuid), public.mirror_conversation_referral_log(uuid, uuid, uuid), public.mirror_listen_phrases(uuid),
  public.mirror_listen_phrase_add(uuid, text, text, text), public.mirror_listen_phrase_retire(uuid), public.mirror_my_export_conversations()
  from public, anon;
grant execute on function public.mirror_conversation_mine(), public.mirror_conversation_start(), public.mirror_conversation_answer_save(uuid, text, text),
  public.mirror_conversation_share(uuid, uuid, jsonb), public.mirror_conversation_discard(uuid), public.mirror_conversations_shared(uuid, uuid),
  public.mirror_conversation_need(uuid, uuid), public.mirror_conversation_referral_log(uuid, uuid, uuid), public.mirror_listen_phrases(uuid),
  public.mirror_listen_phrase_add(uuid, text, text, text), public.mirror_listen_phrase_retire(uuid), public.mirror_my_export_conversations()
  to authenticated, service_role;
