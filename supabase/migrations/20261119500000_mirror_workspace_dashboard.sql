-- The Human Mirror Phase 8, T8.1: the workspace dashboard and the people list (Stephen 11/13/2026 "Now you work ONLY on phase 8 - go";
-- handoff step 8 "T8.1 Workspace dashboard and people list (M) + P2-07 the organization's view of its own audit log").
--
-- Rules
--   * Coordinators and organization admins of the organization only, with the authenticator (mirror.coordinates). Volunteers: no.
--   * Only people this organization works with now (organization_individuals active) and knows (mirror.known_to_org: it created them,
--     or they accepted its invitation). Invited people who have not said yes show only as a count.
--   * Every item passes the one gate for THIS organization (mirror.allowed with p_org): everyday topics, and private topics only where
--     the person shares that topic with this organization. Nothing is counted that the viewer may not see (no hidden counts; T6.1 finding 1).
--   * Each private topic shown for a person is logged as a look (mirror.allowed with table 'workspace_dashboard' / 'workspace_people'),
--     so the person sees it under "Who looked".
--   * Hope-by dates are the person's own hopes: the dashboard says "hope-by date this week or passed", never "late" or "overdue".
--   * Appointments come with T8.5; the dashboard has no appointments list yet.
--   * P2-07: an organization admin reads their own organization's audit log (role_permissions org_admin / audit / view, already seeded).
--     Who did it is shown by member name, never by email; a person is named only if known to the organization. Reading the log is
--     itself logged (category 'audit'). The platform admin's view of every organization stays with P2-08.
--   * No new tables. Functions only; signed-in users only (anon none).

-- the private topics (and general) this organization may see for one person, checked quietly ('_probe' is never logged)
create or replace function mirror.org_sees(p_individual uuid, p_org uuid) returns text[]
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(array_agg(c), '{}') from unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) c
  where coalesce((mirror.allowed(p_individual, c, 'view', p_org, '_probe', null) ->> 'ok')::boolean, false);
$$;

-- log one look per private topic actually shown for a person
create or replace function mirror.log_private_looks(p_individual uuid, p_org uuid, p_cats text[], p_table text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare c text;
begin
  for c in select distinct x from unnest(coalesce(p_cats, '{}')) x where x <> 'general' loop
    perform mirror.allowed(p_individual, c, 'view', p_org, p_table, null);
  end loop;
end $$;

-- ---------------------------------------------------------------- the dashboard
create or replace function public.mirror_workspace_dashboard(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  r record;
  v_ok text[];
  v_cats text[];
  v_needs jsonb := '[]'::jsonb;
  v_steps jsonb := '[]'::jsonb;
  v_help jsonb := '[]'::jsonb;
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  for r in select i.id, i.preferred_name from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
           where oi.organization_id = p_org and oi.status = 'active' and mirror.known_to_org(i.id, p_org) loop
    v_ok := mirror.org_sees(r.id, p_org);
    if cardinality(v_ok) = 0 then continue; end if;
    -- urgent needs still open
    v_needs := v_needs || coalesce((select jsonb_agg(jsonb_build_object('person_id', r.id, 'person', r.preferred_name, 'id', n.id, 'title', n.title,
        'area', d.title, 'status', n.status, 'private', n.category <> 'general', 'since', n.created_at))
      from mirror.needs n join mirror.dimensions d on d.key = n.dimension_key
      where n.individual_id = r.id and n.urgency = 'urgent' and n.status in ('identified', 'planning', 'in_progress') and n.category = any (v_ok)), '[]'::jsonb);
    -- open steps whose hope-by date is within the next 7 days or has passed
    v_steps := v_steps || coalesce((select jsonb_agg(jsonb_build_object('person_id', r.id, 'person', r.preferred_name, 'id', a.id, 'title', a.title,
        'due_on', a.due_on, 'who', a.who, 'helper', a.helper, 'private', a.category <> 'general',
        'for_goal', (select g.title from mirror.goals g where g.id = a.goal_id), 'for_need', (select n.title from mirror.needs n where n.id = a.need_id)))
      from mirror.action_items a
      where a.individual_id = r.id and a.status = 'open' and a.due_on is not null and a.due_on <= current_date + 7 and a.category = any (v_ok)), '[]'::jsonb);
    -- "I'd like help with this" answers
    v_help := v_help || coalesce((select jsonb_agg(jsonb_build_object('person_id', r.id, 'person', r.preferred_name, 'set_title', s.title,
        'prompt', q.prompt, 'note', x.note, 'at', x.answered_at, 'private', q.category <> 'general'))
      from mirror.assessment_responses x
      join mirror.assessments ax on ax.id = x.assessment_id
      join mirror.question_sets s on s.id = ax.set_id
      join mirror.reflection_questions q on q.id = x.question_id
      where ax.individual_id = r.id and x.superseded_at is null and x.state = 'needs_help' and q.category = any (v_ok)), '[]'::jsonb);
    -- log the private topics shown for this person
    select array_agg(distinct c) into v_cats from (
        select n.category c from mirror.needs n where n.individual_id = r.id and n.urgency = 'urgent'
          and n.status in ('identified', 'planning', 'in_progress') and n.category = any (v_ok)
        union select a.category from mirror.action_items a where a.individual_id = r.id and a.status = 'open' and a.due_on is not null
          and a.due_on <= current_date + 7 and a.category = any (v_ok)
        union select q.category from mirror.assessment_responses x join mirror.assessments ax on ax.id = x.assessment_id
          join mirror.reflection_questions q on q.id = x.question_id
          where ax.individual_id = r.id and x.superseded_at is null and x.state = 'needs_help' and q.category = any (v_ok)) z;
    perform mirror.log_private_looks(r.id, p_org, v_cats, 'workspace_dashboard');
  end loop;

  return jsonb_build_object(
    'people', (select jsonb_build_object(
        'active', count(*) filter (where oi.status = 'active'),
        'invited', count(*) filter (where oi.status = 'invited'),
        'ended', count(*) filter (where oi.status = 'ended'),
        'started_this_month', count(*) filter (where oi.status = 'active' and oi.started_on >= date_trunc('month', current_date)::date))
      from mirror.organization_individuals oi where oi.organization_id = p_org),
    'urgent_needs', coalesce((select jsonb_agg(e order by e ->> 'since') from jsonb_array_elements(v_needs) e), '[]'::jsonb),
    'due_steps', coalesce((select jsonb_agg(e order by e ->> 'due_on', e ->> 'person') from jsonb_array_elements(v_steps) e), '[]'::jsonb),
    'help', coalesce((select jsonb_agg(e order by e ->> 'at' desc) from (select e from jsonb_array_elements(v_help) e order by e ->> 'at' desc limit 100) t), '[]'::jsonb),
    'today', current_date);
end $$;

-- ---------------------------------------------------------------- counts beside each person on the people list
-- one row per active, known person: open needs, urgent needs, open steps, goals working toward (visible topics only)
create or replace function public.mirror_people_counts(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  r record;
  v_ok text[];
  v_cats text[];
  v_out jsonb := '[]'::jsonb;
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  for r in select oi.individual_id as id from mirror.organization_individuals oi
           where oi.organization_id = p_org and oi.status = 'active' and mirror.known_to_org(oi.individual_id, p_org) loop
    v_ok := mirror.org_sees(r.id, p_org);
    v_out := v_out || jsonb_build_object('id', r.id,
      'needs_open', (select count(*) from mirror.needs n where n.individual_id = r.id and n.status in ('identified', 'planning', 'in_progress') and n.category = any (v_ok)),
      'needs_urgent', (select count(*) from mirror.needs n where n.individual_id = r.id and n.urgency = 'urgent'
                        and n.status in ('identified', 'planning', 'in_progress') and n.category = any (v_ok)),
      'steps_open', (select count(*) from mirror.action_items a where a.individual_id = r.id and a.status = 'open' and a.category = any (v_ok)),
      'goals_active', (select count(*) from mirror.goals g where g.individual_id = r.id and g.status = 'active' and g.category = any (v_ok)),
      'last_change', greatest(
        (select max(n.updated_at) from mirror.needs n where n.individual_id = r.id and n.category = any (v_ok)),
        (select max(a.updated_at) from mirror.action_items a where a.individual_id = r.id and a.category = any (v_ok)),
        (select max(g.updated_at) from mirror.goals g where g.individual_id = r.id and g.category = any (v_ok))));
    select array_agg(distinct c) into v_cats from (
        select n.category c from mirror.needs n where n.individual_id = r.id and n.status in ('identified', 'planning', 'in_progress') and n.category = any (v_ok)
        union select a.category from mirror.action_items a where a.individual_id = r.id and a.status = 'open' and a.category = any (v_ok)
        union select g.category from mirror.goals g where g.individual_id = r.id and g.status = 'active' and g.category = any (v_ok)) z;
    perform mirror.log_private_looks(r.id, p_org, v_cats, 'workspace_people');
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------- P2-07: the organization's own audit log (organization admins)
-- newest first, 100 at a time; p_before = the last id seen (for "show older"); p_individual = one person only (optional)
create or replace function public.mirror_org_audit(p_org uuid, p_before bigint default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_rows jsonb;
begin
  if coalesce(mirror.my_role(p_org), '') <> 'org_admin'
     or not exists (select 1 from mirror.role_permissions p where p.role = 'org_admin' and p.category = 'audit' and p.action = 'view') then
    raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'at', a.at,
      'who', coalesce(om.name, case when a.actor_role = 'self' then 'The person' when a.actor_role = 'view_as' then 'Office (view as)'
                                    else 'Someone no longer listed' end),
      'role', a.actor_role, 'action', a.action, 'category', a.category, 'what', a.table_name, 'reason', a.reason,
      'person_id', case when a.individual_id is not null and mirror.known_to_org(a.individual_id, p_org) then a.individual_id end,
      'person', case when a.individual_id is null then null when mirror.known_to_org(a.individual_id, p_org) then i.preferred_name
                     else 'A person not on your list' end) order by a.id desc), '[]'::jsonb)
    into v_rows
    from (select * from mirror.audit_logs x where x.organization_id = p_org and (p_before is null or x.id < p_before)
            and (p_individual is null or x.individual_id = p_individual) order by x.id desc limit 100) a
    left join mirror.organization_members om on om.organization_id = p_org and om.auth_email = a.actor_email
    left join mirror.individuals i on i.id = a.individual_id;
  perform mirror.audit(p_individual, p_org, 'org_admin', 'view', 'audit', 'audit_logs', null);
  return jsonb_build_object('rows', v_rows, 'more', jsonb_array_length(v_rows) = 100);
end $$;

revoke all on function mirror.org_sees(uuid, uuid), mirror.log_private_looks(uuid, uuid, text[], text) from public, anon, authenticated;
grant execute on function mirror.org_sees(uuid, uuid), mirror.log_private_looks(uuid, uuid, text[], text) to service_role;
revoke all on function public.mirror_workspace_dashboard(uuid), public.mirror_people_counts(uuid), public.mirror_org_audit(uuid, bigint, uuid) from public, anon;
grant execute on function public.mirror_workspace_dashboard(uuid), public.mirror_people_counts(uuid), public.mirror_org_audit(uuid, bigint, uuid)
  to authenticated, service_role;
