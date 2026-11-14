-- The Human Mirror Phase 8, T8.6: benefits applications with renewal and appeal dates (Stephen 11/13/2026 "go"; handoff step 13).
--
-- The record already exists: mirror.benefit_records (Phase 4, Daily Number "Benefits and renewal dates": program, agency, status
-- considering / applied / active / denied / appealing / ended, applied, approved, renewal-due, appeal-by and end dates, note), saved
-- through mirror_dn_save('benefit', ..., p_individual) under the topic Money (financial), every change in mirror.dn_changes. The person
-- already sees renewal and appeal warnings on their own page. T8.6 adds the organization's side:
--   1. public.mirror_benefits(individual, org): one person's benefit records for a coordinator who may see Money for that person through
--      that organization (the look is logged for the person, as every private look), with who changed each last and when.
--   2. public.mirror_benefit_dates(org): the dashboard list: renewals due in the next 30 days or passed (still active or appealing) and
--      appeal deadlines in the next 30 days, for the people this organization works with who share Money with it. Others are not counted.
-- Adding and changing go through the existing mirror_dn_save (needs "see and change" for Money). The workspace offers no "remove":
-- the person removes their own records (D-37). No new tables.

create or replace function public.mirror_benefits(p_individual uuid default null, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
begin
  r := mirror.allowed(v_id, 'financial', 'view', p_org, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  if (r ->> 'role') <> 'self' and p_org is null then raise exception 'Choose your organization first.' using errcode = '22023'; end if;
  if exists (select 1 from mirror.benefit_records b where b.individual_id = v_id) then
    perform mirror.allowed(v_id, 'financial', 'view', p_org, 'benefit_records', null);   -- logged: a look at Money
  end if;
  return jsonb_build_object('self', (r ->> 'role') = 'self',
    'can_edit', coalesce((mirror.allowed(v_id, 'financial', 'edit', p_org, '_probe', null) ->> 'ok')::boolean, false),
    'today', (now() at time zone 'America/Chicago')::date,
    'benefits', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'program', b.program, 'kind', b.kind, 'agency', b.agency, 'status', b.status,
        'applied_on', b.applied_on, 'approved_on', b.approved_on, 'renewal_on', b.renewal_on, 'appeal_by', b.appeal_by, 'ends_on', b.ends_on,
        'note', b.note, 'updated_at', b.updated_at, 'income_source_id', b.income_source_id, 'noncash_id', b.noncash_id, 'expense_id', b.expense_id,
        'last_by', (select c.actor_role from mirror.dn_changes c where c.table_name = 'benefit_records' and c.row_id = b.id::text order by c.at desc, c.id desc limit 1))
        order by array_position(array['appealing', 'denied', 'applied', 'active', 'considering', 'ended'], b.status), b.program)
      from mirror.benefit_records b where b.individual_id = v_id), '[]'::jsonb));
end $$;

create or replace function public.mirror_benefit_dates(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  r record;
  v_today date := (now() at time zone 'America/Chicago')::date;
  v_out jsonb := '[]'::jsonb;
  v_rows jsonb;
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  for r in select i.id, i.preferred_name from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
           where oi.organization_id = p_org and oi.status = 'active' and mirror.known_to_org(i.id, p_org)
             and exists (select 1 from mirror.benefit_records b where b.individual_id = i.id
                          and ((b.renewal_on <= v_today + 30 and b.status in ('active', 'appealing'))
                            or (b.appeal_by between v_today and v_today + 30 and b.status in ('denied', 'appealing', 'active')))) loop
    if not coalesce((mirror.allowed(r.id, 'financial', 'view', p_org, '_probe', null) ->> 'ok')::boolean, false) then continue; end if;
    select jsonb_agg(x) into v_rows from (
      select jsonb_build_object('person_id', r.id, 'person', r.preferred_name, 'id', b.id, 'program', b.program, 'status', b.status,
               'what', 'renewal', 'on', b.renewal_on, 'passed', b.renewal_on < v_today) x
        from mirror.benefit_records b where b.individual_id = r.id and b.renewal_on <= v_today + 30 and b.status in ('active', 'appealing')
      union all
      select jsonb_build_object('person_id', r.id, 'person', r.preferred_name, 'id', b.id, 'program', b.program, 'status', b.status,
               'what', 'appeal', 'on', b.appeal_by, 'passed', false)
        from mirror.benefit_records b where b.individual_id = r.id and b.appeal_by between v_today and v_today + 30
         and b.status in ('denied', 'appealing', 'active')) t;
    v_out := v_out || coalesce(v_rows, '[]'::jsonb);
    perform mirror.allowed(r.id, 'financial', 'view', p_org, 'workspace_dashboard', null);   -- logged for the person
  end loop;
  return jsonb_build_object('today', v_today,
    'dates', coalesce((select jsonb_agg(e order by e ->> 'on', e ->> 'person') from jsonb_array_elements(v_out) e), '[]'::jsonb));
end $$;

revoke all on function public.mirror_benefits(uuid, uuid), public.mirror_benefit_dates(uuid) from public, anon;
grant execute on function public.mirror_benefits(uuid, uuid), public.mirror_benefit_dates(uuid) to authenticated, service_role;
