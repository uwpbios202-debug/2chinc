
-- ---------------------------------------------------------------- Mirror referrals
create table mirror.referrals (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  suggestion_id uuid references mirror.resource_suggestions(id) on delete set null,
  chpms_org_id text not null,
  chpms_program_id text,
  org_name text not null,
  program_name text,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  status text not null default 'awaiting_consent'
    check (status in ('awaiting_consent', 'consented', 'referred', 'declined', 'withdrawn')),
  help_needed text[] not null default '{}',
  note_to_program text check (note_to_program is null or length(note_to_program) <= 2000),
  proposed_by text not null,
  proposed_by_role text not null,
  -- what the person agreed to share (typed by the person on their own page)
  first_name text check (first_name is null or length(first_name) between 1 and 80),
  last_name text check (last_name is null or length(last_name) between 1 and 80),
  share_email text check (share_email is null or length(share_email) <= 200),
  share_phone text check (share_phone is null or length(share_phone) <= 40),
  household_size int check (household_size is null or household_size between 1 and 20),
  consent_name text check (consent_name is null or length(consent_name) <= 200),
  consent_text text,
  consent_at timestamptz,
  chpms_referral_id uuid references public.chpms_referrals(id) on delete set null,
  referred_by text,
  referred_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint referrals_consent check ((status in ('consented', 'referred')) <= (consent_at is not null and coalesce(btrim(consent_name), '') <> '')),
  constraint referrals_contact check ((status in ('consented', 'referred')) <= (coalesce(share_email, share_phone) is not null)),
  constraint referrals_sent check ((status = 'referred') <= (chpms_referral_id is not null or referred_at is not null))
);
create index referrals_person on mirror.referrals (individual_id, status);
create unique index referrals_one_open on mirror.referrals (individual_id, organization_id, chpms_org_id, coalesce(chpms_program_id, ''))
  where status in ('awaiting_consent', 'consented');
create trigger referrals_touch before update on mirror.referrals for each row execute function mirror.touch();

create table mirror.referral_events (
  id bigint generated always as identity primary key,
  referral_id uuid not null references mirror.referrals(id) on delete cascade,
  action text not null,
  detail text check (detail is null or length(detail) <= 2000),
  by_email text not null,
  by_role text not null,
  at timestamptz not null default now()
);
create index referral_events_r on mirror.referral_events (referral_id, at);

create trigger referrals_no_truncate before truncate on mirror.referrals for each statement execute function mirror.resource_no_truncate();
create trigger referral_events_no_truncate before truncate on mirror.referral_events for each statement execute function mirror.resource_no_truncate();

alter table mirror.referrals enable row level security;
alter table mirror.referral_events enable row level security;
revoke all on mirror.referrals, mirror.referral_events from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.referrals, mirror.referral_events to service_role;

-- ---------------------------------------------------------------- the words the person agrees to (kept with each consent)
create or replace function mirror.referral_consent_words(r mirror.referrals) returns text
language sql stable set search_path = mirror, public as $$
  select 'I agree that ' || (select o.name from mirror.organizations o where o.id = r.organization_id)
      || ' may refer me to ' || r.org_name || coalesce(' (' || r.program_name || ')', '')
      || ' and share with them my name' || case when r.share_email is not null then ', my email' else '' end
      || case when r.share_phone is not null then ', my phone' else '' end
      || case when r.household_size is not null then ', how many people live with me' else '' end
      || case when cardinality(r.help_needed) > 0 then ', the help I need (' || array_to_string(r.help_needed, ', ') || ')' else '' end
      || case when r.note_to_program is not null then ' and this note: "' || r.note_to_program || '"' else '' end
      || '. Nothing else from my Mirror is shared. I can take this back at any time.';
$$;

create or replace function mirror.referral_event(p_ref uuid, p_action text, p_detail text, p_role text) returns void
language sql security definer set search_path = mirror, public as $$
  insert into mirror.referral_events (referral_id, action, detail, by_email, by_role) values (p_ref, p_action, p_detail, lower(auth.email()), p_role);
$$;

-- ---------------------------------------------------------------- one referral as the page sees it
create or replace function mirror.referral_json(r mirror.referrals) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', r.id, 'organization_id', r.organization_id,
    'organization', (select o.name from mirror.organizations o where o.id = r.organization_id),
    'suggestion_id', r.suggestion_id, 'org_name', r.org_name, 'program_name', r.program_name, 'program_id', r.chpms_program_id,
    'private', r.category <> 'general', 'status', r.status, 'help_needed', to_jsonb(r.help_needed), 'note_to_program', r.note_to_program,
    'proposed_by_role', r.proposed_by_role, 'first_name', r.first_name, 'last_name', r.last_name,
    'share_email', r.share_email, 'share_phone', r.share_phone, 'household_size', r.household_size,
    'consent_name', r.consent_name, 'consent_text', r.consent_text, 'consent_at', r.consent_at,
    'consent_words', mirror.referral_consent_words(r),
    'ref_no', (select c.ref_no from public.chpms_referrals c where c.id = r.chpms_referral_id),
    'directory_status', (select c.status from public.chpms_referrals c where c.id = r.chpms_referral_id),
    'sent_on', (select c.sent_on from public.chpms_referrals c where c.id = r.chpms_referral_id),
    'referred_at', r.referred_at, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'history', coalesce((select jsonb_agg(jsonb_build_object('action', e.action, 'detail', e.detail, 'by_role', e.by_role, 'at', e.at) order by e.at, e.id)
       from mirror.referral_events e where e.referral_id = r.id), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------- list (the person: all theirs they may see; a coordinator: their organization's)
create or replace function public.mirror_referrals(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_self boolean;
  v_ok text[] := '{}';
  c text;
begin
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'view') then v_ok := v_ok || c; end if;
  end loop;
  if exists (select 1 from mirror.referrals x where x.individual_id = v_id) then
    perform mirror.allowed(v_id, 'general', 'view', null, 'referrals', null);
  end if;
  return jsonb_build_object('self', v_self,
    'can_send', not v_self and coalesce(public.chpms_role(), 'navigator_preview') in ('staff', 'field', 'navigator'),
    'organizations', case when v_self then coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name) order by o.name)
        from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
       where oi.individual_id = v_id and oi.status = 'active'), '[]'::jsonb) end,
    'referrals', coalesce((select jsonb_agg(mirror.referral_json(x) order by
        array_position(array['awaiting_consent', 'consented', 'referred', 'declined', 'withdrawn'], x.status), x.created_at desc)
      from mirror.referrals x where x.individual_id = v_id and x.category = any (v_ok)
        and (v_self or x.organization_id = (r ->> 'organization_id')::uuid)), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- propose a referral for a program on the person's list
-- A coordinator (with "see and change" for the topic) proposes for their own organization; the person may ask an organization
-- they work with. Either way nothing is shared until the person types their consent.
create or replace function public.mirror_referral_propose(p_suggestion uuid, p_org uuid default null, p_help text[] default null,
  p_note text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  s mirror.resource_suggestions;
  g jsonb;
  v_org uuid;
  o public.chpms_orgs;
  pr public.chpms_programs;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_help text[];
  x mirror.referrals;
begin
  select * into s from mirror.resource_suggestions where id = p_suggestion;
  if not found then raise exception 'That program is not on the list.' using errcode = 'P0002'; end if;
  g := mirror.require(s.individual_id, s.category, 'edit', null, 'referrals', null);
  if (g ->> 'role') = 'self' then
    if p_org is null or not exists (select 1 from mirror.organization_individuals oi join mirror.organizations og on og.id = oi.organization_id and og.active
                                     where oi.individual_id = s.individual_id and oi.organization_id = p_org and oi.status = 'active') then
      raise exception 'Choose an organization you work with to make the referral.' using errcode = '22023';
    end if;
    v_org := p_org;
  else
    v_org := (g ->> 'organization_id')::uuid;
    if p_org is not null and p_org <> v_org then raise exception 'You can propose referrals only for your own organization.' using errcode = '42501'; end if;
  end if;
  if s.chpms_program_id is null then raise exception 'That program is no longer in the directory.' using errcode = 'P0002'; end if;
  select * into pr from public.chpms_programs where program_id = s.chpms_program_id;
  select * into o from public.chpms_orgs where org_id = pr.org_id;
  if o.our_relationship = 'do_not_refer' then
    raise exception 'The office has marked % "Do not refer". Ask the office first.', o.legal_name using errcode = '42501';
  end if;
  if length(coalesce(v_note, '')) > 2000 then raise exception 'The note is too long (2,000 letters at most).' using errcode = '22023'; end if;
  select coalesce(array_agg(distinct h order by h), '{}') into v_help from unnest(coalesce(p_help, '{}')) h
   where h in (select a.category from public.chpms_program_assist a where a.program_id = pr.program_id and a.provided);
  if exists (select 1 from mirror.referrals y where y.individual_id = s.individual_id and y.organization_id = v_org
              and y.chpms_org_id = o.org_id and coalesce(y.chpms_program_id, '') = coalesce(pr.program_id, '')
              and y.status in ('awaiting_consent', 'consented')) then
    raise exception 'A referral to this program is already waiting.' using errcode = '23505';
  end if;
  insert into mirror.referrals (individual_id, organization_id, suggestion_id, chpms_org_id, chpms_program_id, org_name, program_name,
    category, help_needed, note_to_program, proposed_by, proposed_by_role)
  values (s.individual_id, v_org, s.id, o.org_id, pr.program_id, o.legal_name, pr.program_name, s.category, v_help, v_note,
    lower(auth.email()), g ->> 'role')
  returning * into x;
  perform mirror.referral_event(x.id, 'proposed', null, g ->> 'role');
  return mirror.referral_json(x);
end $$;

-- ---------------------------------------------------------------- the person agrees (types their full name) or says no
create or replace function public.mirror_referral_consent(p_id uuid, p_first text, p_last text, p_share_email boolean, p_phone text,
  p_household int, p_consent_name text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  x mirror.referrals;
  g jsonb;
  v_first text := btrim(coalesce(p_first, ''));
  v_last text := btrim(coalesce(p_last, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_typed text := btrim(regexp_replace(coalesce(p_consent_name, ''), '\s+', ' ', 'g'));
  v_email text;
begin
  select * into x from mirror.referrals where id = p_id;
  if not found then raise exception 'That referral is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(x.individual_id, x.category, 'edit', null, 'referrals', x.id::text);
  if (g ->> 'role') <> 'self' then
    raise exception 'Only the person agrees to a referral, on their own page.' using errcode = '42501';
  end if;
  if x.status <> 'awaiting_consent' then raise exception 'This referral is no longer waiting for your answer.' using errcode = '22023'; end if;
  if length(v_first) = 0 or length(v_last) = 0 then raise exception 'First and last name are required.' using errcode = '22023'; end if;
  if length(v_first) > 80 or length(v_last) > 80 then raise exception 'Please keep each name to 80 letters.' using errcode = '22023'; end if;
  if v_phone is not null and (length(v_phone) > 40 or v_phone !~ '^[0-9()+. -]{7,40}$') then
    raise exception 'That phone number does not look right.' using errcode = '22023';
  end if;
  if coalesce(p_share_email, false) then
    select i.auth_email into v_email from mirror.individuals i where i.id = x.individual_id;
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Give a phone number or share your email so the program can reach you.' using errcode = '22023';
  end if;
  if p_household is not null and (p_household < 1 or p_household > 20) then
    raise exception 'How many people live with you (1 to 20)?' using errcode = '22023';
  end if;
  if lower(v_typed) <> lower(v_first || ' ' || v_last) then
    raise exception 'To agree, type your first and last name exactly as above.' using errcode = '22023';
  end if;
  update mirror.referrals set first_name = v_first, last_name = v_last, share_email = v_email, share_phone = v_phone,
    household_size = p_household where id = x.id returning * into x;
  update mirror.referrals set status = 'consented', consent_name = v_typed, consent_at = now(),
    consent_text = mirror.referral_consent_words(x) where id = x.id returning * into x;
  perform mirror.referral_event(x.id, 'consented', 'Typed: ' || v_typed, 'self');
  return mirror.referral_json(x);
end $$;

create or replace function public.mirror_referral_decline(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare x mirror.referrals; g jsonb;
begin
  select * into x from mirror.referrals where id = p_id;
  if not found then raise exception 'That referral is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(x.individual_id, x.category, 'edit', null, 'referrals', x.id::text);
  if (g ->> 'role') <> 'self' then raise exception 'Only the person says no to a referral.' using errcode = '42501'; end if;
  if x.status <> 'awaiting_consent' then raise exception 'This referral is no longer waiting for your answer.' using errcode = '22023'; end if;
  update mirror.referrals set status = 'declined', closed_at = now() where id = x.id returning * into x;
  perform mirror.referral_event(x.id, 'declined', null, 'self');
  return mirror.referral_json(x);
end $$;

-- ---------------------------------------------------------------- take consent back (the person, any time)
-- Before the referral is made: nothing was shared. After: the directory referral is withdrawn if it was not yet sent to the program,
-- and a note on it tells whoever made it that the person took consent back.
create or replace function public.mirror_referral_withdraw(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare x mirror.referrals; g jsonb; c public.chpms_referrals;
begin
  select * into x from mirror.referrals where id = p_id;
  if not found then raise exception 'That referral is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(x.individual_id, x.category, 'edit', null, 'referrals', x.id::text);
  if (g ->> 'role') <> 'self' then raise exception 'Only the person takes back their consent.' using errcode = '42501'; end if;
  if x.status not in ('consented', 'referred') then raise exception 'There is no consent to take back.' using errcode = '22023'; end if;
  if x.chpms_referral_id is not null then
    select * into c from public.chpms_referrals where id = x.chpms_referral_id;
    if c.status = 'new' then
      update public.chpms_referrals set status = 'withdrawn', closed_reason = 'The person took back consent in their Mirror.',
        closed_at = now(), updated_at = now() where id = c.id;
    end if;
    insert into public.chpms_referral_events (referral_id, actor_email, actor_name, actor_role, action, detail)
    values (x.chpms_referral_id, null, 'The person (Human Mirror)', null, 'note',
      'The person took back consent in their Mirror on ' || to_char(now() at time zone 'America/Chicago', 'MM/DD/YYYY')
      || case when c.status = 'new' then '. Withdrawn before it was sent.' else '. Tell the program they no longer agree to be referred.' end);
  end if;
  update mirror.referrals set status = 'withdrawn', closed_at = now() where id = x.id returning * into x;
  perform mirror.referral_event(x.id, 'withdrawn', null, 'self');
  return mirror.referral_json(x);
end $$;

-- ---------------------------------------------------------------- make the referral: a coordinator of that organization, after consent
-- Uses the directory's own public.chpms_referral_save, so every CHPMS rule applies (office staff, field staff or an active Navigator,
-- "do not refer", name and contact, typed consent, 30 a day, the office email for field staff and Navigators).
create or replace function public.mirror_referral_send(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare x mirror.referrals; g jsonb; v_ref uuid;
begin
  select * into x from mirror.referrals where id = p_id;
  if not found then raise exception 'That referral is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(x.individual_id, x.category, 'edit', x.organization_id, 'referrals', x.id::text);
  if (g ->> 'role') = 'self' then
    raise exception 'Someone from the organization makes the referral after you agree.' using errcode = '42501';
  end if;
  if x.status <> 'consented' then raise exception 'The person has not agreed to this referral (or it is closed).' using errcode = '22023'; end if;
  if coalesce(public.chpms_role(), 'navigator_preview') not in ('staff', 'field', 'navigator') then
    raise exception 'Referrals are made by office staff, field staff or an active Housing Navigator.' using errcode = '42501';
  end if;
  v_ref := public.chpms_referral_save(jsonb_build_object('org_id', x.chpms_org_id, 'program_id', x.chpms_program_id,
    'first_name', x.first_name, 'last_name', x.last_name, 'phone', x.share_phone, 'email', x.share_email,
    'household_size', x.household_size, 'help_needed', to_jsonb(x.help_needed),
    'notes', concat_ws(E'\n', x.note_to_program, 'Consent typed in the Human Mirror on ' || to_char(x.consent_at at time zone 'America/Chicago', 'MM/DD/YYYY') || ': ' || x.consent_text),
    'consent', true, 'consent_name', x.consent_name));
  update mirror.referrals set status = 'referred', chpms_referral_id = v_ref, referred_by = lower(auth.email()), referred_at = now()
   where id = x.id returning * into x;
  perform mirror.referral_event(x.id, 'referred', 'Directory referral #' || (select c.ref_no from public.chpms_referrals c where c.id = v_ref), g ->> 'role');
  return mirror.referral_json(x);
end $$;

-- ---------------------------------------------------------------- the person's own download
create or replace function public.mirror_my_export_referrals() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.require(v, 'general', 'view', null, 'referrals', null);
  return coalesce((select jsonb_agg(jsonb_build_object('to', x.org_name, 'program', x.program_name,
      'through', (select o.name from mirror.organizations o where o.id = x.organization_id), 'status', x.status,
      'shared', jsonb_build_object('first_name', x.first_name, 'last_name', x.last_name, 'email', x.share_email, 'phone', x.share_phone,
                                   'household_size', x.household_size, 'help_needed', to_jsonb(x.help_needed), 'note', x.note_to_program),
      'consent_typed', x.consent_name, 'consent_words', x.consent_text, 'consent_at', x.consent_at, 'referred_at', x.referred_at,
      'history', coalesce((select jsonb_agg(jsonb_build_object('action', e.action, 'detail', e.detail, 'by', e.by_role, 'at', e.at) order by e.at, e.id)
         from mirror.referral_events e where e.referral_id = x.id), '[]'::jsonb)) order by x.created_at)
    from mirror.referrals x where x.individual_id = v), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function mirror.referral_consent_words(mirror.referrals), mirror.referral_event(uuid, text, text, text),
  mirror.referral_json(mirror.referrals) from public, anon, authenticated;
grant execute on function mirror.referral_consent_words(mirror.referrals), mirror.referral_event(uuid, text, text, text),
  mirror.referral_json(mirror.referrals) to service_role;
revoke all on function public.mirror_referrals(uuid), public.mirror_referral_propose(uuid, uuid, text[], text),
  public.mirror_referral_consent(uuid, text, text, boolean, text, int, text), public.mirror_referral_decline(uuid),
  public.mirror_referral_withdraw(uuid), public.mirror_referral_send(uuid), public.mirror_my_export_referrals() from public, anon;
grant execute on function public.mirror_referrals(uuid), public.mirror_referral_propose(uuid, uuid, text[], text),
  public.mirror_referral_consent(uuid, text, text, boolean, text, int, text), public.mirror_referral_decline(uuid),
  public.mirror_referral_withdraw(uuid), public.mirror_referral_send(uuid), public.mirror_my_export_referrals() to authenticated, service_role;
