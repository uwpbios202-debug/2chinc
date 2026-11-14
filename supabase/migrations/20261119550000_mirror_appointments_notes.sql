-- The Human Mirror Phase 8, T8.5: appointments and interactions (Stephen 11/13/2026 "go"; handoff step 12). Database part.
--
-- Rules (D-35, defaults chosen by Claude for Stephen to confirm)
--   Appointments
--   (a) An organization's coordinator adds an appointment with the person (for their own organization) only with the person's
--       "see and change" for its topic. The topic follows the area of life chosen (mirror.dimension_category), else everyday.
--   (b) The person sees every appointment of theirs, with every organization, on My appointments. They may add their own
--       appointments (doctor, court, school ...): those are theirs alone; no organization sees them.
--   (c) On an organization's appointment the person may say "I can't make it" (cancelled, with a note) or that it happened; the
--       organization changes the rest (time, place, status). Statuses: scheduled, done, cancelled, not_happened ("didn't happen");
--       never "missed" or "no-show". Every change is in the appointment's own history. Nothing is deleted one by one.
--   (d) The dashboard lists the organization's scheduled appointments for today and the next 7 days, shared topics only.
--   (e) No reminder email yet: reminders come with Phase 9 (T9.2) through mirror.notification_ok (D-25).
--   Interactions (contact notes: visit, call, message, meeting, other)
--   (f) A coordinator writes a note about a contact with the person only with the person's "see and change" for the note's topic.
--   (g) No secret notes: the person sees every note any organization writes about them, with who wrote it and when.
--   (h) An organization sees only its own notes, in topics the person shares with it. Private looks are logged for the person.
--   (i) Notes never change: a mistake is fixed by a new note that corrects it (linked). Deleting the whole Mirror removes them.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only; authenticated and anon none; row security on.

-- ---------------------------------------------------------------- tables
create table mirror.appointments (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  organization_id uuid references mirror.organizations(id) on delete restrict,   -- null = the person's own appointment
  dimension_key text references mirror.dimensions(key),
  category text not null default 'general',
  title text not null check (length(btrim(title)) between 1 and 200),
  starts_at timestamptz not null,
  ends_at timestamptz,
  place text check (place is null or length(place) <= 300),
  with_whom text check (with_whom is null or length(with_whom) <= 200),
  detail text check (detail is null or length(detail) <= 1000),
  status text not null default 'scheduled' check (status in ('scheduled', 'done', 'cancelled', 'not_happened')),
  created_by text not null,
  created_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or ends_at >= starts_at)
);
create index appointments_person on mirror.appointments (individual_id, starts_at);
create index appointments_org on mirror.appointments (organization_id, starts_at) where organization_id is not null;

create table mirror.appointment_events (
  id bigint generated always as identity primary key,
  appointment_id uuid not null references mirror.appointments(id) on delete cascade,
  from_status text,
  to_status text not null,
  note text check (note is null or length(note) <= 1000),
  by_email text not null,
  by_role text not null,
  at timestamptz not null default now()
);
create index appointment_events_a on mirror.appointment_events (appointment_id, at);

create table mirror.interactions (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  category text not null default 'general',
  kind text not null check (kind in ('visit', 'call', 'message', 'meeting', 'other')),
  at timestamptz not null,
  summary text not null check (length(btrim(summary)) between 1 and 4000),
  corrects uuid references mirror.interactions(id) on delete cascade,
  by_email text not null,
  by_name text,
  by_role text not null,
  created_at timestamptz not null default now()
);
create index interactions_person on mirror.interactions (individual_id, at);

-- notes never change; deleted only with the whole Mirror (the person's row is already gone when the cascade arrives)
create or replace function mirror.interactions_append_only() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'TRUNCATE' then raise exception 'Notes are never emptied.' using errcode = '42501'; end if;
  if tg_op = 'DELETE' and not exists (select 1 from mirror.individuals i where i.id = old.individual_id) then return old; end if;
  raise exception 'Notes never change. Add a new note that corrects it.' using errcode = '42501';
end $$;
create trigger interactions_append_only before update or delete on mirror.interactions for each row execute function mirror.interactions_append_only();
create trigger interactions_no_truncate before truncate on mirror.interactions for each statement execute function mirror.interactions_append_only();
create trigger appointments_touch before update on mirror.appointments for each row execute function mirror.touch();
create trigger appointments_no_truncate before truncate on mirror.appointments for each statement execute function mirror.resource_no_truncate();
create trigger appointment_events_no_truncate before truncate on mirror.appointment_events for each statement execute function mirror.resource_no_truncate();

alter table mirror.appointments enable row level security;
alter table mirror.appointment_events enable row level security;
alter table mirror.interactions enable row level security;
revoke all on mirror.appointments, mirror.appointment_events, mirror.interactions from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.appointments, mirror.appointment_events, mirror.interactions to service_role;
revoke all on function mirror.interactions_append_only() from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function mirror.appointment_json(a mirror.appointments) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', a.id, 'organization_id', a.organization_id,
    'organization', (select o.name from mirror.organizations o where o.id = a.organization_id), 'own', a.organization_id is null,
    'dimension_key', a.dimension_key, 'area', (select d.title from mirror.dimensions d where d.key = a.dimension_key),
    'category', a.category, 'private', a.category <> 'general', 'title', a.title, 'starts_at', a.starts_at, 'ends_at', a.ends_at,
    'place', a.place, 'with_whom', a.with_whom, 'detail', a.detail, 'status', a.status, 'created_by_role', a.created_by_role,
    'history', coalesce((select jsonb_agg(jsonb_build_object('from', v.from_status, 'to', v.to_status, 'note', v.note, 'by_role', v.by_role, 'at', v.at)
        order by v.at, v.id) from mirror.appointment_events v where v.appointment_id = a.id), '[]'::jsonb));
$$;

create or replace function mirror.interaction_json(x mirror.interactions) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', x.id, 'organization_id', x.organization_id,
    'organization', (select o.name from mirror.organizations o where o.id = x.organization_id),
    'category', x.category, 'private', x.category <> 'general', 'kind', x.kind, 'at', x.at, 'summary', x.summary,
    'corrects', x.corrects, 'corrected', exists (select 1 from mirror.interactions c where c.corrects = x.id),
    'by', coalesce(x.by_name, 'Someone from ' || (select o.name from mirror.organizations o where o.id = x.organization_id)),
    'by_role', x.by_role, 'created_at', x.created_at);
$$;

create or replace function mirror.is_the_person(p_individual uuid) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select exists (select 1 from mirror.individuals i where i.id = p_individual and i.auth_email = lower(auth.email()));
$$;

-- the topics a caller may view / edit for one person through one organization (quiet probe)
create or replace function mirror.org_topics(p_individual uuid, p_org uuid, p_action text) returns text[]
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(array_agg(c), '{}') from unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) c
  where coalesce((mirror.allowed(p_individual, c, p_action, p_org, '_probe', null) ->> 'ok')::boolean, false);
$$;

-- ---------------------------------------------------------------- appointments
-- The person (no p_org): all theirs. A coordinator (p_org): that organization's, in shared topics, plus what they may add.
create or replace function public.mirror_appointments(p_individual uuid default null, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_ok text[];
  v_cats text[];
begin
  r := mirror.allowed(v_id, 'general', 'view', p_org, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  if (r ->> 'role') = 'self' then
    return jsonb_build_object('self', true, 'appointments', coalesce((select jsonb_agg(mirror.appointment_json(a) order by a.starts_at desc)
      from mirror.appointments a where a.individual_id = v_id), '[]'::jsonb));
  end if;
  if p_org is null then raise exception 'Choose your organization first.' using errcode = '22023'; end if;
  v_ok := mirror.org_topics(v_id, p_org, 'view');
  select array_agg(distinct a.category) into v_cats from mirror.appointments a
   where a.individual_id = v_id and a.organization_id = p_org and a.category = any (v_ok);
  perform mirror.log_private_looks(v_id, p_org, v_cats, 'appointments');
  return jsonb_build_object('self', false, 'can_edit', to_jsonb(mirror.org_topics(v_id, p_org, 'edit')),
    'appointments', coalesce((select jsonb_agg(mirror.appointment_json(a) order by a.starts_at desc)
      from mirror.appointments a where a.individual_id = v_id and a.organization_id = p_org and a.category = any (v_ok)), '[]'::jsonb));
end $$;

-- add (no id) or change (id). p: individual_id, organization_id (coordinators), dimension_key, title, starts_at, ends_at, place,
-- with_whom, detail, status, note
create or replace function public.mirror_appointment_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_aid uuid := nullif(p ->> 'id', '')::uuid;
  v_ind uuid := nullif(p ->> 'individual_id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_dim text := nullif(p ->> 'dimension_key', '');
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_start timestamptz := nullif(p ->> 'starts_at', '')::timestamptz;
  v_end timestamptz := nullif(p ->> 'ends_at', '')::timestamptz;
  v_place text := nullif(btrim(coalesce(p ->> 'place', '')), '');
  v_with text := nullif(btrim(coalesce(p ->> 'with_whom', '')), '');
  v_detail text := nullif(btrim(coalesce(p ->> 'detail', '')), '');
  v_status text := nullif(p ->> 'status', '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  a mirror.appointments;
  g jsonb;
  v_cat text;
  v_self boolean;
  v_from text;
begin
  if v_dim is not null and not exists (select 1 from mirror.dimensions d where d.key = v_dim) then raise exception 'Unknown area of life.' using errcode = '22023'; end if;
  if v_status is not null and v_status not in ('scheduled', 'done', 'cancelled', 'not_happened') then raise exception 'Unknown status.' using errcode = '22023'; end if;
  if length(coalesce(v_note, '')) > 1000 then raise exception 'The note is too long (1,000 letters at most).' using errcode = '22023'; end if;

  if v_aid is null then
    if length(v_title) = 0 then raise exception 'Say in a few words what the appointment is for.' using errcode = '22023'; end if;
    if v_start is null then raise exception 'Choose the day and time.' using errcode = '22023'; end if;
    v_cat := coalesce(mirror.dimension_category(v_dim), 'general');
    if v_org is null then
      v_ind := mirror.me();   -- the person's own appointment
      g := mirror.require(v_ind, v_cat, 'edit', null, 'appointments', null);
      if (g ->> 'role') <> 'self' then raise exception 'Choose your organization first.' using errcode = '22023'; end if;
    else
      if v_ind is null then raise exception 'Choose the person.' using errcode = '22023'; end if;
      g := mirror.require(v_ind, v_cat, 'edit', v_org, 'appointments', null);
      if (g ->> 'role') = 'self' or (g ->> 'organization_id')::uuid is distinct from v_org then
        raise exception 'Coordinators add appointments for their own organization.' using errcode = '42501';
      end if;
    end if;
    insert into mirror.appointments (individual_id, organization_id, dimension_key, category, title, starts_at, ends_at, place, with_whom, detail,
      created_by, created_by_role)
    values (v_ind, v_org, v_dim, v_cat, left(v_title, 200), v_start, v_end, v_place, v_with, v_detail, lower(auth.email()), g ->> 'role')
    returning * into a;
    perform mirror.appointment_event_add(a.id, null, 'scheduled', v_note, g ->> 'role');
    return mirror.appointment_json(a);
  end if;

  select * into a from mirror.appointments where id = v_aid;
  if not found then raise exception 'That appointment is not available.' using errcode = 'P0002'; end if;
  v_self := mirror.is_the_person(a.individual_id);
  g := mirror.require(a.individual_id, a.category, 'edit', case when v_self then null else a.organization_id end, 'appointments', a.id::text);
  v_from := a.status;
  v_status := coalesce(v_status, a.status);
  if v_self and a.organization_id is not null then
    -- an organization's appointment: the person says "I can't make it" or that it happened
    if v_status = a.status and v_note is null then return mirror.appointment_json(a); end if;
    if v_status not in ('cancelled', 'done') or a.status <> 'scheduled' then
      raise exception 'You can say you can''t make it, or that it happened. The organization changes the rest.' using errcode = '42501';
    end if;
    update mirror.appointments set status = v_status where id = a.id returning * into a;
    perform mirror.appointment_event_add(a.id, v_from, v_status, v_note, 'self');
    return mirror.appointment_json(a);
  end if;
  if not v_self and ((g ->> 'organization_id')::uuid is distinct from a.organization_id or a.organization_id is null) then
    raise exception 'Only the organization that set up this appointment changes it.' using errcode = '42501';
  end if;
  -- full change (the person on their own appointment; the organization on its own)
  v_cat := coalesce(mirror.dimension_category(coalesce(v_dim, a.dimension_key)), 'general');
  if p ? 'dimension_key' and v_cat <> a.category then
    perform mirror.require(a.individual_id, v_cat, 'edit', case when v_self then null else a.organization_id end, 'appointments', a.id::text);
  else
    v_dim := a.dimension_key; v_cat := a.category;
  end if;
  if p ? 'title' and length(v_title) = 0 then raise exception 'Say in a few words what the appointment is for.' using errcode = '22023'; end if;
  if (a.title, a.starts_at, a.ends_at, a.place, a.with_whom, a.detail, a.status, a.dimension_key)
     is not distinct from (case when p ? 'title' then left(v_title, 200) else a.title end, coalesce(v_start, a.starts_at),
       case when p ? 'ends_at' then v_end else a.ends_at end, case when p ? 'place' then v_place else a.place end,
       case when p ? 'with_whom' then v_with else a.with_whom end, case when p ? 'detail' then v_detail else a.detail end, v_status, v_dim)
     and v_note is null then
    return mirror.appointment_json(a);
  end if;
  update mirror.appointments set
      title = case when p ? 'title' then left(v_title, 200) else title end,
      starts_at = coalesce(v_start, starts_at),
      ends_at = case when p ? 'ends_at' then v_end else ends_at end,
      place = case when p ? 'place' then v_place else place end,
      with_whom = case when p ? 'with_whom' then v_with else with_whom end,
      detail = case when p ? 'detail' then v_detail else detail end,
      dimension_key = v_dim, category = v_cat, status = v_status
   where id = a.id returning * into a;
  perform mirror.appointment_event_add(a.id, v_from, v_status,
    left(concat_ws(' ', v_note, case when v_from = v_status then '(details changed)' end), 1000), g ->> 'role');
  return mirror.appointment_json(a);
end $$;

create or replace function mirror.appointment_event_add(p_app uuid, p_from text, p_to text, p_note text, p_role text) returns void
language sql security definer set search_path = mirror, public as $$
  insert into mirror.appointment_events (appointment_id, from_status, to_status, note, by_email, by_role)
  values (p_app, p_from, p_to, p_note, lower(auth.email()), p_role);
$$;

-- the dashboard: this organization's scheduled appointments today and the next 7 days (shared topics only)
create or replace function public.mirror_workspace_appointments(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  r record;
  v_ok text[];
  v_cats text[];
  v_out jsonb := '[]'::jsonb;
  v_from timestamptz := (date_trunc('day', now() at time zone 'America/Chicago')) at time zone 'America/Chicago';
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  for r in select distinct a.individual_id as id, i.preferred_name from mirror.appointments a join mirror.individuals i on i.id = a.individual_id
           join mirror.organization_individuals oi on oi.individual_id = a.individual_id and oi.organization_id = p_org and oi.status = 'active'
           where a.organization_id = p_org and a.status = 'scheduled' and a.starts_at >= v_from and a.starts_at < v_from + interval '8 days'
             and mirror.known_to_org(a.individual_id, p_org) loop
    v_ok := mirror.org_sees(r.id, p_org);
    v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('person_id', r.id, 'person', r.preferred_name, 'id', a.id, 'title', a.title,
        'starts_at', a.starts_at, 'place', a.place, 'with_whom', a.with_whom, 'private', a.category <> 'general'))
      from mirror.appointments a where a.individual_id = r.id and a.organization_id = p_org and a.status = 'scheduled'
        and a.starts_at >= v_from and a.starts_at < v_from + interval '8 days' and a.category = any (v_ok)), '[]'::jsonb);
    select array_agg(distinct a.category) into v_cats from mirror.appointments a where a.individual_id = r.id and a.organization_id = p_org
      and a.status = 'scheduled' and a.starts_at >= v_from and a.starts_at < v_from + interval '8 days' and a.category = any (v_ok);
    perform mirror.log_private_looks(r.id, p_org, v_cats, 'workspace_dashboard');
  end loop;
  return jsonb_build_object('from', v_from, 'appointments',
    coalesce((select jsonb_agg(e order by e ->> 'starts_at') from jsonb_array_elements(v_out) e), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- interactions (contact notes)
create or replace function public.mirror_interactions(p_individual uuid default null, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_ok text[];
  v_cats text[];
begin
  r := mirror.allowed(v_id, 'general', 'view', p_org, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  if (r ->> 'role') = 'self' then
    return jsonb_build_object('self', true, 'notes', coalesce((select jsonb_agg(mirror.interaction_json(x) order by x.at desc, x.created_at desc)
      from mirror.interactions x where x.individual_id = v_id), '[]'::jsonb));
  end if;
  if p_org is null then raise exception 'Choose your organization first.' using errcode = '22023'; end if;
  v_ok := mirror.org_topics(v_id, p_org, 'view');
  select array_agg(distinct x.category) into v_cats from mirror.interactions x
   where x.individual_id = v_id and x.organization_id = p_org and x.category = any (v_ok);
  perform mirror.log_private_looks(v_id, p_org, v_cats, 'interactions');
  return jsonb_build_object('self', false, 'can_edit', to_jsonb(mirror.org_topics(v_id, p_org, 'edit')),
    'notes', coalesce((select jsonb_agg(mirror.interaction_json(x) order by x.at desc, x.created_at desc)
      from mirror.interactions x where x.individual_id = v_id and x.organization_id = p_org and x.category = any (v_ok)), '[]'::jsonb));
end $$;

-- p: individual_id, organization_id, category (general or a private topic), kind, at, summary, corrects
create or replace function public.mirror_interaction_add(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_ind uuid := nullif(p ->> 'individual_id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_cat text := coalesce(nullif(p ->> 'category', ''), 'general');
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'other');
  v_at timestamptz := coalesce(nullif(p ->> 'at', '')::timestamptz, now());
  v_sum text := btrim(coalesce(p ->> 'summary', ''));
  v_corr uuid := nullif(p ->> 'corrects', '')::uuid;
  c mirror.interactions;
  x mirror.interactions;
  g jsonb;
begin
  if v_cat not in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial') then raise exception 'Unknown topic.' using errcode = '22023'; end if;
  if v_kind not in ('visit', 'call', 'message', 'meeting', 'other') then raise exception 'Unknown kind of contact.' using errcode = '22023'; end if;
  if length(v_sum) = 0 then raise exception 'Write what happened.' using errcode = '22023'; end if;
  if length(v_sum) > 4000 then raise exception 'Please keep the note to 4,000 letters.' using errcode = '22023'; end if;
  if v_at > now() + interval '10 minutes' then raise exception 'A note is about something that already happened.' using errcode = '22023'; end if;
  if v_ind is null or v_org is null then raise exception 'Choose the person and your organization.' using errcode = '22023'; end if;
  if v_corr is not null then
    select * into c from mirror.interactions where id = v_corr;
    if not found or c.individual_id <> v_ind or c.organization_id <> v_org then raise exception 'That note is not available.' using errcode = 'P0002'; end if;
    v_cat := c.category; v_kind := c.kind; v_at := c.at;
  end if;
  g := mirror.require(v_ind, v_cat, 'edit', v_org, 'interactions', null);
  if (g ->> 'role') = 'self' or (g ->> 'organization_id')::uuid is distinct from v_org then
    raise exception 'Notes are written by the organization you work with.' using errcode = '42501';
  end if;
  insert into mirror.interactions (individual_id, organization_id, category, kind, at, summary, corrects, by_email, by_name, by_role)
  values (v_ind, v_org, v_cat, v_kind, v_at, v_sum, v_corr, lower(auth.email()),
          (select m.name from mirror.organization_members m where m.organization_id = v_org and m.auth_email = lower(auth.email())), g ->> 'role')
  returning * into x;
  return mirror.interaction_json(x);
end $$;

-- ---------------------------------------------------------------- the person's own download
create or replace function public.mirror_my_export_appointments() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.require(v, 'general', 'view', null, 'appointments', null);
  return jsonb_build_object(
    'appointments', coalesce((select jsonb_agg(mirror.appointment_json(a) - 'organization_id' - 'category' order by a.starts_at)
      from mirror.appointments a where a.individual_id = v), '[]'::jsonb),
    'notes_about_me', coalesce((select jsonb_agg(mirror.interaction_json(x) - 'organization_id' - 'category' order by x.at)
      from mirror.interactions x where x.individual_id = v), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function mirror.appointment_json(mirror.appointments), mirror.interaction_json(mirror.interactions), mirror.is_the_person(uuid),
  mirror.org_topics(uuid, uuid, text), mirror.appointment_event_add(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function mirror.appointment_json(mirror.appointments), mirror.interaction_json(mirror.interactions), mirror.is_the_person(uuid),
  mirror.org_topics(uuid, uuid, text), mirror.appointment_event_add(uuid, text, text, text, text) to service_role;
revoke all on function public.mirror_appointments(uuid, uuid), public.mirror_appointment_save(jsonb), public.mirror_workspace_appointments(uuid),
  public.mirror_interactions(uuid, uuid), public.mirror_interaction_add(jsonb), public.mirror_my_export_appointments() from public, anon;
grant execute on function public.mirror_appointments(uuid, uuid), public.mirror_appointment_save(jsonb), public.mirror_workspace_appointments(uuid),
  public.mirror_interactions(uuid, uuid), public.mirror_interaction_add(jsonb), public.mirror_my_export_appointments() to authenticated, service_role;
