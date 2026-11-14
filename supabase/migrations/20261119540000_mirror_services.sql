-- The Human Mirror Phase 8, T8.4: services and enrollments (Stephen 11/13/2026 "go"; handoff step 11). Database part.
--
-- What an organization itself provides (a food pantry, rides, a clothing closet, budgeting class, housing search help ...) and who is
-- getting it. Programs of OTHER organizations stay in the resource directory (Phase 7: suggestions and referrals).
--
-- Rules (D-34, defaults chosen by Claude for Stephen to confirm)
--   (a) The organization's own list of services: organization admins add, change and retire services (with the authenticator).
--       Coordinators read it. A service is never deleted once someone was enrolled; it is retired (active = false).
--   (b) Each service may name one area of life; its privacy topic follows that area (mirror.dimension_category), else everyday.
--       A service's area cannot change once someone is enrolled (make a new service instead), so no enrollment changes topic.
--   (c) A coordinator enrolls a person, and changes or ends an enrollment, only with the person's "see and change" for that topic,
--       through the one gate (mirror.require with the organization), so a private-topic service needs that topic shared.
--   (d) The person sees every one of their enrollments, with every organization, on My Mirror (My services), with the history, and
--       may say they stopped getting it (status 'ended', their note kept). Only the organization marks one finished or on hold.
--       Nobody removes one by one; deleting the whole Mirror removes them (cascade).
--   (e) An organization sees only its own enrollments, and only in topics the person shares with it. Counts beside a service count
--       only enrollments the viewer may see (no hidden counts, T6.1 finding 1). Private looks are logged for the person.
--   (f) Every change goes into the enrollment's own history (who: the person or a coordinator; what; when). No email is sent.
--   (g) Statuses: active (getting it), paused (on hold), completed (finished), ended (stopped). Dates are plain dates; nothing is "late".
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only; authenticated and anon none; row security on.

-- ---------------------------------------------------------------- tables
create table mirror.services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 120),
  description text check (description is null or length(description) <= 1000),
  dimension_key text references mirror.dimensions(key),
  category text not null default 'general',
  active boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index services_org_name on mirror.services (organization_id, lower(btrim(name)));

create table mirror.service_enrollments (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  service_id uuid not null references mirror.services(id) on delete restrict,
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  category text not null,
  status text not null default 'active' check (status in ('active', 'paused', 'completed', 'ended')),
  started_on date not null default current_date,
  ended_on date,
  note text check (note is null or length(note) <= 1000),
  enrolled_by text not null,
  enrolled_by_role text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ended_on is null or ended_on >= started_on),
  check ((status in ('completed', 'ended')) = (ended_on is not null))
);
create index service_enrollments_person on mirror.service_enrollments (individual_id);
create index service_enrollments_service on mirror.service_enrollments (service_id);
-- one open enrollment per person per service
create unique index service_enrollments_open on mirror.service_enrollments (individual_id, service_id) where status in ('active', 'paused');

create table mirror.service_enrollment_events (
  id bigint generated always as identity primary key,
  enrollment_id uuid not null references mirror.service_enrollments(id) on delete cascade,
  from_status text,
  to_status text not null,
  note text check (note is null or length(note) <= 1000),
  by_email text not null,
  by_role text not null,
  at timestamptz not null default now()
);
create index service_enrollment_events_e on mirror.service_enrollment_events (enrollment_id, at);

create trigger services_touch before update on mirror.services for each row execute function mirror.touch();
create trigger service_enrollments_touch before update on mirror.service_enrollments for each row execute function mirror.touch();
create trigger services_no_truncate before truncate on mirror.services for each statement execute function mirror.resource_no_truncate();
create trigger service_enrollments_no_truncate before truncate on mirror.service_enrollments for each statement execute function mirror.resource_no_truncate();
create trigger service_enrollment_events_no_truncate before truncate on mirror.service_enrollment_events for each statement execute function mirror.resource_no_truncate();

alter table mirror.services enable row level security;
alter table mirror.service_enrollments enable row level security;
alter table mirror.service_enrollment_events enable row level security;
revoke all on mirror.services, mirror.service_enrollments, mirror.service_enrollment_events from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.services, mirror.service_enrollments, mirror.service_enrollment_events to service_role;

-- ---------------------------------------------------------------- helpers
create or replace function mirror.enrollment_json(e mirror.service_enrollments) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', e.id, 'service_id', e.service_id, 'service', s.name, 'description', s.description,
    'organization_id', e.organization_id, 'organization', (select o.name from mirror.organizations o where o.id = e.organization_id),
    'area', (select d.title from mirror.dimensions d where d.key = s.dimension_key), 'category', e.category, 'private', e.category <> 'general',
    'status', e.status, 'started_on', e.started_on, 'ended_on', e.ended_on, 'note', e.note, 'enrolled_by_role', e.enrolled_by_role,
    'created_at', e.created_at, 'updated_at', e.updated_at,
    'history', coalesce((select jsonb_agg(jsonb_build_object('from', v.from_status, 'to', v.to_status, 'note', v.note, 'by_role', v.by_role, 'at', v.at)
        order by v.at, v.id) from mirror.service_enrollment_events v where v.enrollment_id = e.id), '[]'::jsonb))
  from mirror.services s where s.id = e.service_id;
$$;

create or replace function mirror.enrollment_event(p_enr uuid, p_from text, p_to text, p_note text, p_role text) returns void
language sql security definer set search_path = mirror, public as $$
  insert into mirror.service_enrollment_events (enrollment_id, from_status, to_status, note, by_email, by_role)
  values (p_enr, p_from, p_to, p_note, lower(auth.email()), p_role);
$$;

-- ---------------------------------------------------------------- the organization's list of services
create or replace function public.mirror_services(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_admin boolean;
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  v_admin := coalesce(mirror.my_role(p_org), '') = 'org_admin';
  return jsonb_build_object('can_manage', v_admin,
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'description', s.description,
        'dimension_key', s.dimension_key, 'area', (select d.title from mirror.dimensions d where d.key = s.dimension_key),
        'private', s.category <> 'general', 'active', s.active,
        'has_enrollments', exists (select 1 from mirror.service_enrollments e where e.service_id = s.id),
        -- counts only over enrollments this viewer may see (quiet probe; a count is not a look at a person)
        'getting_it', (select count(*) from mirror.service_enrollments e where e.service_id = s.id and e.status = 'active'
                        and coalesce((mirror.allowed(e.individual_id, e.category, 'view', p_org, '_probe', null) ->> 'ok')::boolean, false)),
        'on_hold', (select count(*) from mirror.service_enrollments e where e.service_id = s.id and e.status = 'paused'
                        and coalesce((mirror.allowed(e.individual_id, e.category, 'view', p_org, '_probe', null) ->> 'ok')::boolean, false)))
        order by s.active desc, lower(s.name)) from mirror.services s where s.organization_id = p_org), '[]'::jsonb));
end $$;

create or replace function public.mirror_service_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_desc text := nullif(btrim(coalesce(p ->> 'description', '')), '');
  v_dim text := nullif(p ->> 'dimension_key', '');
  v_active boolean := coalesce((p ->> 'active')::boolean, true);
  s mirror.services;
begin
  if v_id is not null then
    select * into s from mirror.services where id = v_id;
    if not found then raise exception 'That service is not available.' using errcode = 'P0002'; end if;
    v_org := s.organization_id;
  end if;
  if v_org is null or not mirror.coordinates(v_org) or coalesce(mirror.my_role(v_org), '') <> 'org_admin' then
    raise exception 'Organization admins add and change services (with your authenticator code).' using errcode = '42501';
  end if;
  if length(v_name) = 0 then raise exception 'Give the service a name.' using errcode = '22023'; end if;
  if length(v_name) > 120 then raise exception 'Please keep the name to 120 letters; add more in the description.' using errcode = '22023'; end if;
  if length(coalesce(v_desc, '')) > 1000 then raise exception 'The description is too long (1,000 letters at most).' using errcode = '22023'; end if;
  if v_dim is not null and not exists (select 1 from mirror.dimensions d where d.key = v_dim) then
    raise exception 'Unknown area of life.' using errcode = '22023';
  end if;
  if v_id is null then
    insert into mirror.services (organization_id, name, description, dimension_key, category, active, created_by)
    values (v_org, v_name, v_desc, v_dim, coalesce(mirror.dimension_category(v_dim), 'general'), v_active, lower(auth.email()))
    returning * into s;
  else
    if s.dimension_key is distinct from v_dim and exists (select 1 from mirror.service_enrollments e where e.service_id = s.id) then
      raise exception 'People are enrolled in this service, so its area of life stays as it is. Add a new service instead.' using errcode = '22023';
    end if;
    update mirror.services set name = v_name, description = v_desc, dimension_key = v_dim,
      category = coalesce(mirror.dimension_category(v_dim), 'general'), active = v_active
     where id = s.id returning * into s;
  end if;
  perform mirror.audit(null, v_org, 'org_admin', 'service_save', 'organization', 'services', s.id::text);
  return jsonb_build_object('id', s.id, 'name', s.name, 'active', s.active);
exception when unique_violation then
  raise exception 'Your organization already has a service with that name.' using errcode = '23505';
end $$;

-- ---------------------------------------------------------------- one person's enrollments
-- The person (no p_org): all of theirs, with every organization. A coordinator (p_org): that organization's, in shared topics,
-- plus the active services they may enroll the person in.
create or replace function public.mirror_enrollments(p_individual uuid default null, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_self boolean;
  v_ok text[] := '{}';
  v_edit text[] := '{}';
  v_cats text[];
  c text;
begin
  r := mirror.allowed(v_id, 'general', 'view', p_org, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  if v_self then
    return jsonb_build_object('self', true, 'enrollments', coalesce((select jsonb_agg(mirror.enrollment_json(e)
        order by array_position(array['active', 'paused', 'completed', 'ended'], e.status), e.started_on desc)
      from mirror.service_enrollments e where e.individual_id = v_id), '[]'::jsonb));
  end if;
  if p_org is null then raise exception 'Choose your organization first.' using errcode = '22023'; end if;
  foreach c in array array['general', 'health', 'mental_health', 'safety', 'legal', 'financial'] loop
    if coalesce((mirror.allowed(v_id, c, 'view', p_org, '_probe', null) ->> 'ok')::boolean, false) then v_ok := v_ok || c; end if;
    if coalesce((mirror.allowed(v_id, c, 'edit', p_org, '_probe', null) ->> 'ok')::boolean, false) then v_edit := v_edit || c; end if;
  end loop;
  select array_agg(distinct e.category) into v_cats from mirror.service_enrollments e
   where e.individual_id = v_id and e.organization_id = p_org and e.category = any (v_ok);
  perform mirror.log_private_looks(v_id, p_org, v_cats, 'service_enrollments');
  return jsonb_build_object('self', false, 'can_edit', to_jsonb(v_edit),
    'enrollments', coalesce((select jsonb_agg(mirror.enrollment_json(e)
        order by array_position(array['active', 'paused', 'completed', 'ended'], e.status), e.started_on desc)
      from mirror.service_enrollments e where e.individual_id = v_id and e.organization_id = p_org and e.category = any (v_ok)), '[]'::jsonb),
    'services', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
        'area', (select d.title from mirror.dimensions d where d.key = s.dimension_key), 'private', s.category <> 'general') order by lower(s.name))
      from mirror.services s where s.organization_id = p_org and s.active and s.category = any (v_edit)
        and not exists (select 1 from mirror.service_enrollments e where e.service_id = s.id and e.individual_id = v_id
                          and e.status in ('active', 'paused'))), '[]'::jsonb));
end $$;

-- enroll (p_service set, no p_id) or change one (p_id): status, dates, note
create or replace function public.mirror_enrollment_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_enr uuid := nullif(p ->> 'id', '')::uuid;
  v_svc uuid := nullif(p ->> 'service_id', '')::uuid;
  v_ind uuid := nullif(p ->> 'individual_id', '')::uuid;
  v_status text := nullif(p ->> 'status', '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_start date := nullif(p ->> 'started_on', '')::date;
  v_end date := nullif(p ->> 'ended_on', '')::date;
  s mirror.services;
  e mirror.service_enrollments;
  g jsonb;
  v_from text;
begin
  if length(coalesce(v_note, '')) > 1000 then raise exception 'The note is too long (1,000 letters at most).' using errcode = '22023'; end if;
  if v_status is not null and v_status not in ('active', 'paused', 'completed', 'ended') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;

  if v_enr is null then
    select * into s from mirror.services where id = v_svc;
    if not found or not s.active then raise exception 'That service is not available.' using errcode = 'P0002'; end if;
    if v_ind is null then raise exception 'Choose the person.' using errcode = '22023'; end if;
    g := mirror.require(v_ind, s.category, 'edit', s.organization_id, 'service_enrollments', null);
    if (g ->> 'role') = 'self' then raise exception 'The organization enrolls you in its services.' using errcode = '42501'; end if;
    if exists (select 1 from mirror.service_enrollments x where x.individual_id = v_ind and x.service_id = s.id and x.status in ('active', 'paused')) then
      raise exception 'They are already enrolled in this service.' using errcode = '23505';
    end if;
    v_start := coalesce(v_start, current_date);
    if v_start > current_date + 366 then raise exception 'Please choose a start date within the next year.' using errcode = '22023'; end if;
    insert into mirror.service_enrollments (individual_id, service_id, organization_id, category, started_on, note, enrolled_by, enrolled_by_role)
    values (v_ind, s.id, s.organization_id, s.category, v_start, v_note, lower(auth.email()), g ->> 'role')
    returning * into e;
    perform mirror.enrollment_event(e.id, null, 'active', v_note, g ->> 'role');
    return mirror.enrollment_json(e);
  end if;

  select * into e from mirror.service_enrollments where id = v_enr;
  if not found then raise exception 'That enrollment is not available.' using errcode = 'P0002'; end if;
  if v_ind is not null and v_ind <> e.individual_id then raise exception 'That enrollment is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(e.individual_id, e.category, 'edit', case when exists (select 1 from mirror.individuals i where i.id = e.individual_id and i.auth_email = lower(auth.email())) then null else e.organization_id end,
                      'service_enrollments', e.id::text);
  v_from := e.status;
  v_status := coalesce(v_status, e.status);
  if (g ->> 'role') = 'self' then
    -- the person may only say they stopped getting it
    if v_status <> 'ended' or e.status not in ('active', 'paused') then
      raise exception 'You can say you stopped getting a service. The organization records the rest.' using errcode = '42501';
    end if;
    v_start := e.started_on;
    v_end := greatest(current_date, e.started_on);
  else
    if (g ->> 'organization_id')::uuid is distinct from e.organization_id then
      raise exception 'Only the organization that provides this service changes it.' using errcode = '42501';
    end if;
    v_start := coalesce(v_start, e.started_on);
    v_end := case when v_status in ('completed', 'ended') then coalesce(v_end, e.ended_on, greatest(current_date, v_start)) end;
    if v_end is not null and v_end < v_start then raise exception 'The end date is before the start date.' using errcode = '22023'; end if;
    if v_status in ('active', 'paused') and e.status in ('completed', 'ended')
       and exists (select 1 from mirror.service_enrollments x where x.individual_id = e.individual_id and x.service_id = e.service_id
                   and x.status in ('active', 'paused') and x.id <> e.id) then
      raise exception 'They are already enrolled in this service again.' using errcode = '23505';
    end if;
  end if;
  if (e.status, e.started_on, e.ended_on) is not distinct from (v_status, v_start, v_end) and v_note is null then
    return mirror.enrollment_json(e);   -- nothing new
  end if;
  update mirror.service_enrollments set status = v_status, started_on = v_start, ended_on = v_end
   where id = e.id returning * into e;
  perform mirror.enrollment_event(e.id, v_from, v_status,
    left(concat_ws(' ', v_note, case when v_from = v_status then '(dates changed)' end), 1000), g ->> 'role');
  return mirror.enrollment_json(e);
end $$;

-- ---------------------------------------------------------------- the person's own download
create or replace function public.mirror_my_export_services() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.require(v, 'general', 'view', null, 'service_enrollments', null);
  return coalesce((select jsonb_agg(jsonb_build_object('service', x ->> 'service', 'organization', x ->> 'organization', 'area', x ->> 'area',
      'status', x ->> 'status', 'started_on', x ->> 'started_on', 'ended_on', x ->> 'ended_on', 'note', x ->> 'note',
      'history', x -> 'history') order by x ->> 'started_on')
    from (select mirror.enrollment_json(e) x from mirror.service_enrollments e where e.individual_id = v) t), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function mirror.enrollment_json(mirror.service_enrollments), mirror.enrollment_event(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function mirror.enrollment_json(mirror.service_enrollments), mirror.enrollment_event(uuid, text, text, text, text) to service_role;
revoke all on function public.mirror_services(uuid), public.mirror_service_save(jsonb), public.mirror_enrollments(uuid, uuid),
  public.mirror_enrollment_save(jsonb), public.mirror_my_export_services() from public, anon;
grant execute on function public.mirror_services(uuid), public.mirror_service_save(jsonb), public.mirror_enrollments(uuid, uuid),
  public.mirror_enrollment_save(jsonb), public.mirror_my_export_services() to authenticated, service_role;
