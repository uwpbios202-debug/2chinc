-- The Human Mirror T6.1: needs inventory with a life cycle (Stephen 11/13/2026 "Go - T6.1"; DATABASE_DESIGN needs + need_events;
-- Mirror1 Part 4: every need its own record, followed from identified to verified, history kept).
--
-- Rules
--   * Every need belongs to one area of life (mirror.dimensions). Its privacy topic comes from that area, the same way the
--     life-area questions do (D-14): physical health -> health, how you feel inside -> mental_health, ID and legal -> legal,
--     money -> financial, safety -> safety, every other area -> general. Organizations see a need only when they may see its topic.
--   * Life cycle: identified -> planning -> in_progress -> obtained -> verified, or no_longer_needed. Any open status may move to any
--     other open status. "verified" only from "obtained", and only by someone from an organization (a coordinator or org admin
--     with edit access): verified means somebody other than the person confirmed it. The person can always reopen a need.
--     (Default chosen for the open question "who may verify"; recorded in DECISIONS.md D-27 for Stephen to confirm.)
--   * Every status change is a need_events row: who, when, from, to, note. Events are never changed or deleted.
--   * Needs are never deleted one by one ("no longer needed" instead); they go only with the whole Mirror (D-18).
--   * Every read and write passes mirror.allowed (the one gate); private topics are logged as looks, as for answers.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only, no TRUNCATE; authenticated and anon none.

-- ---------------------------------------------------------------- privacy topic of an area of life
create or replace function mirror.dimension_category(p_dimension text) returns text
language sql immutable set search_path = mirror, public as $$
  select case p_dimension
    when 'physical_health' then 'health'
    when 'mental_health' then 'mental_health'
    when 'identity_legal' then 'legal'
    when 'finances' then 'financial'
    when 'safety' then 'safety'
    else 'general' end;
$$;

-- ---------------------------------------------------------------- tables
create table mirror.needs (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  dimension_key text not null references mirror.dimensions(key) on delete restrict,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'financial')),
  title text not null check (length(btrim(title)) between 1 and 200),
  detail text check (detail is null or length(detail) <= 2000),
  urgency text not null default 'soon' check (urgency in ('urgent', 'soon', 'later')),
  status text not null default 'identified'
    check (status in ('identified', 'planning', 'in_progress', 'obtained', 'verified', 'no_longer_needed')),
  identified_by text not null,
  identified_by_role text not null,
  verified_at timestamptz,
  verified_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'verified') = (verified_at is not null))
);
create index needs_person on mirror.needs (individual_id, status);

create table mirror.need_events (
  id bigint generated always as identity primary key,
  need_id uuid not null references mirror.needs(id) on delete cascade,
  at timestamptz not null default now(),
  by_email text not null,
  by_role text not null,
  from_status text,                        -- null when the need was added
  to_status text not null,
  note text check (note is null or length(note) <= 1000)
);
create index need_events_need on mirror.need_events (need_id, at);

create trigger needs_touch before update on mirror.needs for each row execute function mirror.touch();

-- Needs: no deleting one by one (only together with the whole Mirror). Events: append-only.
create or replace function mirror.needs_no_delete() returns trigger language plpgsql set search_path = mirror as $$
begin
  if exists (select 1 from mirror.individuals i where i.id = old.individual_id) then
    raise exception 'Needs are not deleted one by one; mark it "no longer needed" instead.' using errcode = '42501';
  end if;
  return old;
end $$;
create trigger needs_no_delete before delete on mirror.needs for each row execute function mirror.needs_no_delete();

create or replace function mirror.need_events_append_only() returns trigger language plpgsql set search_path = mirror as $$
begin
  if tg_op = 'DELETE' and not exists (select 1 from mirror.needs n where n.id = old.need_id) then return old; end if;
  raise exception 'The history of a need is never changed.' using errcode = '42501';
end $$;
create trigger need_events_append_only before update or delete on mirror.need_events
  for each row execute function mirror.need_events_append_only();

create or replace function mirror.needs_no_truncate() returns trigger language plpgsql set search_path = mirror as $$
begin
  raise exception 'Needs and their history are never emptied in bulk.' using errcode = '42501';
end $$;
create trigger needs_no_truncate before truncate on mirror.needs for each statement execute function mirror.needs_no_truncate();
create trigger need_events_no_truncate before truncate on mirror.need_events for each statement execute function mirror.needs_no_truncate();

-- ---------------------------------------------------------------- one need as the page sees it
create or replace function mirror.need_json(n mirror.needs) returns jsonb
language sql stable set search_path = mirror, public as $$
  select jsonb_build_object('id', n.id, 'dimension', n.dimension_key, 'dimension_title', (select d.title from mirror.dimensions d where d.key = n.dimension_key),
    'category', n.category, 'private', n.category <> 'general', 'title', n.title, 'detail', n.detail, 'urgency', n.urgency,
    'status', n.status, 'identified_by_role', n.identified_by_role, 'verified_at', n.verified_at,
    'created_at', n.created_at, 'updated_at', n.updated_at,
    'last_change', (select jsonb_build_object('at', e.at, 'by_role', e.by_role, 'to', e.to_status, 'note', e.note)
                    from mirror.need_events e where e.need_id = n.id order by e.at desc, e.id desc limit 1));
$$;

-- ---------------------------------------------------------------- list
-- The needs the caller may see, newest change first; needs in topics the caller may not see are only counted ("hidden").
create or replace function public.mirror_needs_list(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_ok text[] := '{}';
  v_add text[] := '{}';
  c text;
  r jsonb;
  v_self boolean := false;
begin
  -- the caller must at least be able to see everyday topics (the person always can); the reason comes back in plain words
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  -- topics with needs: a quiet probe decides; only real looks at private topics are logged (no "tried to open" on every list)
  for c in select distinct n.category from mirror.needs n where n.individual_id = v_id loop
    if mirror.may(v_id, c, 'view') then
      v_ok := v_ok || c;
      perform mirror.allowed(v_id, c, 'view', null, 'needs', null);
    end if;
  end loop;
  -- which topics the caller may add a need in (quiet probe, not logged)
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'edit') then v_add := v_add || c; end if;
  end loop;
  return jsonb_build_object(
    'self', v_self,
    'can_add', to_jsonb(v_add),
    'needs', coalesce((select jsonb_agg(mirror.need_json(n) order by
        case n.status when 'verified' then 2 when 'no_longer_needed' then 2 when 'obtained' then 1 else 0 end,
        case n.urgency when 'urgent' then 0 when 'soon' then 1 else 2 end, n.updated_at desc)
      from mirror.needs n where n.individual_id = v_id and n.category = any (v_ok)), '[]'::jsonb),
    'hidden', (select count(*) from mirror.needs n where n.individual_id = v_id and not (n.category = any (v_ok))));
end $$;

-- ---------------------------------------------------------------- add or edit (title, detail, urgency, area)
create or replace function public.mirror_need_save(p_id uuid, p_dimension text, p_title text, p_detail text default null,
  p_urgency text default 'soon', p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid;
  n mirror.needs;
  g jsonb;
  v_cat text;
  v_title text := btrim(coalesce(p_title, ''));
  v_detail text := nullif(btrim(coalesce(p_detail, '')), '');
begin
  if not exists (select 1 from mirror.dimensions d where d.key = p_dimension) then
    raise exception 'Choose an area of life for this need.' using errcode = '22023';
  end if;
  if length(v_title) = 0 then raise exception 'Say in a few words what you need.' using errcode = '22023'; end if;
  if length(v_title) > 200 then raise exception 'Please keep the need to 200 letters; add more in the details.' using errcode = '22023'; end if;
  if length(coalesce(v_detail, '')) > 2000 then raise exception 'The details are too long (2,000 letters at most).' using errcode = '22023'; end if;
  if coalesce(p_urgency, '') not in ('urgent', 'soon', 'later') then raise exception 'Unknown urgency.' using errcode = '22023'; end if;
  v_cat := mirror.dimension_category(p_dimension);

  if p_id is null then
    v_id := mirror.target_individual(p_individual);
    g := mirror.require(v_id, v_cat, 'edit', null, 'needs', null);
    insert into mirror.needs (individual_id, dimension_key, category, title, detail, urgency, identified_by, identified_by_role)
    values (v_id, p_dimension, v_cat, v_title, v_detail, p_urgency, lower(auth.email()), g ->> 'role')
    returning * into n;
    insert into mirror.need_events (need_id, by_email, by_role, from_status, to_status, note)
    values (n.id, lower(auth.email()), g ->> 'role', null, 'identified', null);
    return mirror.need_json(n);
  end if;

  select * into n from mirror.needs where id = p_id;
  if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  if p_individual is not null and p_individual <> n.individual_id then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(n.individual_id, n.category, 'edit', null, 'needs', n.id::text);
  if v_cat <> n.category then perform mirror.require(n.individual_id, v_cat, 'edit', null, 'needs', n.id::text); end if;
  if (n.dimension_key, n.title, n.detail, n.urgency) is distinct from (p_dimension, v_title, v_detail, p_urgency) then
    update mirror.needs set dimension_key = p_dimension, category = v_cat, title = v_title, detail = v_detail, urgency = p_urgency
     where id = n.id returning * into n;
  end if;
  return mirror.need_json(n);
end $$;

-- ---------------------------------------------------------------- move along the life cycle
create or replace function public.mirror_need_status(p_id uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  n mirror.needs;
  g jsonb;
  v_from text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if coalesce(p_status, '') not in ('identified', 'planning', 'in_progress', 'obtained', 'verified', 'no_longer_needed') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) > 1000 then raise exception 'The note is too long (1,000 letters at most).' using errcode = '22023'; end if;
  select * into n from mirror.needs where id = p_id;
  if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(n.individual_id, n.category, 'edit', null, 'needs', n.id::text);
  if p_status = n.status then return mirror.need_json(n); end if;
  if p_status = 'verified' then
    if (g ->> 'role') not in ('coordinator', 'org_admin') then
      raise exception 'A need is verified by someone from an organization you work with, who confirms it was met.' using errcode = '42501';
    end if;
    if n.status <> 'obtained' then raise exception 'Mark the need as obtained first.' using errcode = '22023'; end if;
  end if;
  v_from := n.status;
  update mirror.needs set status = p_status,
    verified_at = case when p_status = 'verified' then now() end,
    verified_by = case when p_status = 'verified' then lower(auth.email()) end
   where id = n.id returning * into n;
  insert into mirror.need_events (need_id, by_email, by_role, from_status, to_status, note)
  values (n.id, lower(auth.email()), g ->> 'role', v_from, p_status, v_note);
  return mirror.need_json(n);
end $$;

-- ---------------------------------------------------------------- history of one need
create or replace function public.mirror_need_history(p_id uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare n mirror.needs;
begin
  select * into n from mirror.needs where id = p_id;
  if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  perform mirror.require(n.individual_id, n.category, 'view', null, 'need_events', n.id::text);
  return coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'by_role', e.by_role, 'from', e.from_status, 'to', e.to_status, 'note', e.note)
      order by e.at desc, e.id desc) from mirror.need_events e where e.need_id = n.id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- the person's own download of their needs
create or replace function public.mirror_my_export_needs() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('area', d.title, 'need', n.title, 'details', n.detail, 'urgency', n.urgency,
      'status', n.status, 'added', n.created_at, 'verified_at', n.verified_at,
      'history', (select jsonb_agg(jsonb_build_object('at', e.at, 'by', e.by_role, 'from', e.from_status, 'to', e.to_status, 'note', e.note)
                  order by e.at, e.id) from mirror.need_events e where e.need_id = n.id))
      order by n.created_at, n.title, n.id)
    from mirror.needs n join mirror.dimensions d on d.key = n.dimension_key where n.individual_id = v), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- row security and grants
alter table mirror.needs enable row level security;
alter table mirror.need_events enable row level security;
revoke all on mirror.needs, mirror.need_events from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.needs, mirror.need_events to service_role;
grant usage on all sequences in schema mirror to service_role;

revoke all on function mirror.dimension_category(text), mirror.need_json(mirror.needs), mirror.needs_no_delete(),
  mirror.need_events_append_only(), mirror.needs_no_truncate() from public, anon, authenticated;
grant execute on function mirror.dimension_category(text), mirror.need_json(mirror.needs) to service_role;

revoke all on function public.mirror_needs_list(uuid), public.mirror_need_save(uuid, text, text, text, text, uuid),
  public.mirror_need_status(uuid, text, text), public.mirror_need_history(uuid), public.mirror_my_export_needs() from public, anon;
grant execute on function public.mirror_needs_list(uuid), public.mirror_need_save(uuid, text, text, text, text, uuid),
  public.mirror_need_status(uuid, text, text), public.mirror_need_history(uuid), public.mirror_my_export_needs() to authenticated, service_role;
