-- The Human Mirror, Phase 2: T2.1 identity, T2.2 consents and permissions, T2.3 audit (Stephen, 11/13/2026: "yes please").
-- Design: docs/human-mirror/DATABASE_DESIGN.md, SECURITY_PLAN.md (D-06, D-07, D-12, D-13, D-14, D-20).
--
-- Rules this file sets for everything that follows:
--  * Schema `mirror` is closed: anon and authenticated have no USAGE on it and no grant on any table (D-07). It is not in the
--    Data API's exposed schemas. Row security is on with no policies (deny all) as a second lock. service_role only.
--  * Pages reach Mirror data only through public.mirror_* functions (security definer, fixed search_path) that call
--    mirror.allowed() / mirror.require() first. Hiding a button is never the control.
--  * mirror.allowed() decides AND writes the audit row; it never raises, so a refusal's audit row survives. Read functions
--    return a refusal message instead of raising; write functions use mirror.require(), which raises when refused.
--  * No View as for Mirror people (D-12). Workspace members need an authenticator code (aal2, D-13).
-- Nothing here holds a real person: one organization row (2nd Chance Housing Inc) and the permission matrix are seeded.

create schema if not exists mirror;
revoke all on schema mirror from public, anon, authenticated;
grant usage on schema mirror to service_role;

create or replace function mirror.touch() returns trigger language plpgsql set search_path = mirror as $$
begin new.updated_at := now(); return new; end $$;

-- ---------------------------------------------------------------- T2.1 identity and organizations

create table mirror.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null default 'nonprofit' check (kind in ('nonprofit', 'agency', 'navigator', 'other')),
  navigator_id uuid unique references public.navigators(id) on delete set null,  -- a Navigator's own business (D-20)
  is_platform_owner boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index organizations_one_owner on mirror.organizations ((true)) where is_platform_owner;

create table mirror.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  auth_email text not null check (auth_email = lower(trim(auth_email)) and auth_email like '%@%'),
  name text not null,
  role text not null check (role in ('org_admin', 'coordinator', 'volunteer')),
  active boolean not null default true,
  invited_at timestamptz,
  joined_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, auth_email)
);
create index organization_members_email on mirror.organization_members (auth_email) where active;

create table mirror.profiles (
  id uuid primary key default gen_random_uuid(),
  auth_email text not null unique check (auth_email = lower(trim(auth_email))),
  display_name text,
  language text not null default 'en',
  text_size text not null default 'standard' check (text_size in ('standard', 'large')),
  notification_prefs jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Minimal identity: everything else is an answer. No SSN, no ID numbers, birth year only (SECURITY_PLAN 1.10).
create table mirror.individuals (
  id uuid primary key default gen_random_uuid(),
  auth_email text check (auth_email = lower(trim(auth_email))),        -- null: coordinator-assisted person with no email
  preferred_name text not null,
  legal_name text,
  birth_year int check (birth_year between 1900 and 2100),
  created_by_org uuid references mirror.organizations(id) on delete set null,
  safety_sensitive boolean not null default false,                      -- safety mode (SECURITY_PLAN 1.11)
  deletion_requested_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index individuals_email on mirror.individuals (auth_email) where auth_email is not null;

create table mirror.organization_individuals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited', 'active', 'ended')),
  started_on date,
  ended_on date,
  primary_member_id uuid references mirror.organization_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, individual_id)
);
create index organization_individuals_person on mirror.organization_individuals (individual_id);

-- ---------------------------------------------------------------- T2.2 consents and permissions

-- Categories: general (identity basics, vision, strengths, preferences, contribution, goals, actions) and the sensitive ones
-- (D-14). safety_flag = "this person has a safety concern", without detail. organization / audit are not about a person's answers.
create table mirror.consents (
  id uuid primary key default gen_random_uuid(),
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents')),
  access text not null default 'view' check (access in ('view', 'edit')),            -- edit includes view
  granted_at timestamptz not null default now(),
  granted_by text not null,                                                          -- email of who recorded it (normally the person)
  expires_on date,
  revoked_at timestamptz,                                                            -- revoking keeps the row (history)
  revoked_by text,
  created_at timestamptz not null default now()
);
create index consents_open on mirror.consents (individual_id, organization_id) where revoked_at is null;

-- The access matrix as data (SECURITY_PLAN section 2). needs_consent: allowed only with an open consent for that category from
-- the person to that organization (edit needs a consent with access 'edit'). No row = refused. Volunteers get no rows until
-- assigned tasks exist; platform admins get no rows on a person's records (D-12).
create table mirror.role_permissions (
  role text not null check (role in ('self', 'coordinator', 'org_admin', 'volunteer', 'platform_admin')),
  category text not null check (category in ('general', 'health', 'mental_health', 'safety', 'safety_flag', 'legal', 'immigration',
    'financial', 'documents', 'organization', 'audit')),
  action text not null check (action in ('view', 'edit')),
  needs_consent boolean not null default false,
  primary key (role, category, action)
);

insert into mirror.role_permissions (role, category, action, needs_consent)
select 'self', c, a, false
from unnest(array['general', 'health', 'mental_health', 'safety', 'safety_flag', 'legal', 'immigration', 'financial', 'documents']) c,
     unnest(array['view', 'edit']) a
union all select 'self', 'audit', 'view', false
union all
select r, c, a, (c <> 'general' or a = 'edit')
from unnest(array['coordinator', 'org_admin']) r,
     unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents']) c,
     unnest(array['view', 'edit']) a
union all select r, 'safety_flag', 'view', false from unnest(array['coordinator', 'org_admin']) r
union all select 'org_admin', 'organization', a, false from unnest(array['view', 'edit']) a
union all select 'org_admin', 'audit', 'view', false
union all select 'platform_admin', 'organization', a, false from unnest(array['view', 'edit']) a
union all select 'platform_admin', 'audit', 'view', false;

-- ---------------------------------------------------------------- T2.3 audit

-- Append-only, ids and categories only, never content. individual_id has no foreign key: the row outlives a deleted person (D-18).
create table mirror.audit_logs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_email text,
  actor_role text,
  organization_id uuid,
  individual_id uuid,
  action text not null,          -- view, edit, refused, consent_grant, consent_revoke, export, delete_request, ...
  category text,
  table_name text,
  row_id text,
  reason text                    -- for refusals: a short code, never content
);
create index audit_logs_person on mirror.audit_logs (individual_id, at desc);
create index audit_logs_org on mirror.audit_logs (organization_id, at desc);

create or replace function mirror.audit_no_change() returns trigger language plpgsql set search_path = mirror as $$
begin raise exception 'The Mirror audit log cannot be changed or deleted.' using errcode = '42501'; end $$;
create trigger audit_logs_append_only before update or delete on mirror.audit_logs
  for each row execute function mirror.audit_no_change();

create or replace function mirror.audit(p_individual uuid, p_org uuid, p_role text, p_action text, p_category text,
  p_table text default null, p_row text default null, p_reason text default null) returns void
language sql security definer set search_path = mirror, public as $$
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, individual_id, action, category, table_name, row_id, reason)
  values (lower(auth.email()), p_role, p_org, p_individual, p_action, p_category, p_table, p_row, p_reason);
$$;

-- ---------------------------------------------------------------- the gate

-- Who is asking, about whom, for what. Returns jsonb {ok, role, organization_id, reason}. Writes the audit row:
--   members: every sensitive view, every edit, every refusal of a sensitive category; the person themself: never (it is theirs).
-- p_org: when a member belongs to several organizations, the one acting (null = any of theirs that works with the person).
create or replace function mirror.allowed(p_individual uuid, p_category text, p_action text, p_org uuid default null,
  p_table text default null, p_row text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_email text := lower(auth.email());
  v_sensitive boolean := p_category not in ('general', 'safety_flag', 'organization', 'audit');
  v_member boolean := false;
  v_org uuid;
  v_role text;
  m record;
  p mirror.role_permissions;
begin
  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'Sign-in required.');
  end if;
  if public.autopay_view_as_session() then
    perform mirror.audit(p_individual, p_org, 'view_as', 'refused', p_category, p_table, p_row, 'view_as');
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
      perform mirror.audit(p_individual, m.organization_id, m.role, 'refused', p_category, p_table, p_row, 'no_authenticator');
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
      perform mirror.audit(p_individual, m.organization_id, m.role, p_action, p_category, p_table, p_row, null);
    end if;
    return jsonb_build_object('ok', true, 'role', m.role, 'organization_id', m.organization_id);
  end loop;

  if v_member then
    if v_sensitive or p_action = 'edit' then
      perform mirror.audit(p_individual, v_org, v_role, 'refused', p_category, p_table, p_row, 'no_consent');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'The person has not shared this with your organization.');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'Not allowed.');
end $$;

-- For writes: raises when refused (the refusal's audit row is lost with the rolled-back statement; use allowed() where it must stay).
create or replace function mirror.require(p_individual uuid, p_category text, p_action text, p_org uuid default null,
  p_table text default null, p_row text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare r jsonb := mirror.allowed(p_individual, p_category, p_action, p_org, p_table, p_row);
begin
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  return r;
end $$;

-- ---------------------------------------------------------------- the person's "who looked" (SECURITY_PLAN 1.5)

-- For the signed-in person: every logged action by someone else on their record, newest first (no content, never refused rows
-- by the person themself). Empty when the caller is not a Mirror individual.
create or replace function public.mirror_who_looked() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v_id uuid;
begin
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  select id into v_id from mirror.individuals where auth_email = lower(auth.email());
  if v_id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'at', a.at,
      'organization', o.name,
      'who', coalesce(om.name, case a.actor_role when 'view_as' then 'Office (view as)' else 'Someone at ' || coalesce(o.name, 'an organization') end),
      'role', a.actor_role,
      'action', a.action,
      'category', a.category) order by a.at desc)
    from (select * from mirror.audit_logs where individual_id = v_id and coalesce(actor_email, '') <> lower(auth.email())
          order by at desc limit 500) a
    left join mirror.organizations o on o.id = a.organization_id
    left join mirror.organization_members om on om.organization_id = a.organization_id and om.auth_email = a.actor_email), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- triggers, grants, row security

create trigger organizations_touch before update on mirror.organizations for each row execute function mirror.touch();
create trigger organization_members_touch before update on mirror.organization_members for each row execute function mirror.touch();
create trigger profiles_touch before update on mirror.profiles for each row execute function mirror.touch();
create trigger individuals_touch before update on mirror.individuals for each row execute function mirror.touch();
create trigger organization_individuals_touch before update on mirror.organization_individuals for each row execute function mirror.touch();

alter table mirror.organizations enable row level security;
alter table mirror.organization_members enable row level security;
alter table mirror.profiles enable row level security;
alter table mirror.individuals enable row level security;
alter table mirror.organization_individuals enable row level security;
alter table mirror.consents enable row level security;
alter table mirror.role_permissions enable row level security;
alter table mirror.audit_logs enable row level security;

revoke all on all tables in schema mirror from public, anon, authenticated;
revoke all on all sequences in schema mirror from public, anon, authenticated;
revoke all on all functions in schema mirror from public, anon, authenticated;
grant all on all tables in schema mirror to service_role;
grant all on all sequences in schema mirror to service_role;
grant execute on all functions in schema mirror to service_role;
alter default privileges in schema mirror revoke all on tables from public, anon, authenticated;
alter default privileges in schema mirror revoke all on functions from public, anon, authenticated;

revoke all on function public.mirror_who_looked() from public, anon;
grant execute on function public.mirror_who_looked() to authenticated, service_role;

-- ---------------------------------------------------------------- seed

insert into mirror.organizations (name, kind, is_platform_owner) values ('2nd Chance Housing Inc', 'nonprofit', true);
