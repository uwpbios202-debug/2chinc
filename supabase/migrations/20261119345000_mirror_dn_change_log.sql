-- Human Mirror Phase 4 step 5: field-by-field change log for Daily Number edits made by someone helping the person
-- (a coordinator or org admin of an organization the person shares money with). The person's own edits are not logged
-- here (their saves and the daily snapshots already keep them). Stephen 11/13/2026: "a change log that records field by
-- field what a coordinator changed".
--
-- How: an AFTER row trigger on the 8 Daily Number tables. It compares the row before and after, column by column, and
-- writes one line per changed field (added and removed lines: one line with the whole row). Who: the signed-in email
-- (auth.email()); it is skipped when that is the person themself, when nobody is signed in (service jobs, migrations),
-- and when the person is being deleted (the cascade). The organization and role are looked up the same way
-- mirror.allowed() picks them. The page functions (mirror_dn_save / delete / copy) are unchanged.
--
-- The person (and anyone allowed to view their money topic) reads it with public.mirror_dn_changes(); it is part of the
-- download (mirror_my_export -> daily_number -> changes). Staff are named as on "Who looked" (their name, never their email).

create table mirror.dn_changes (
  id bigint generated always as identity primary key,
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  at timestamptz not null default now(),
  actor_email text not null,
  actor_role text not null,
  organization_id uuid references mirror.organizations(id) on delete set null,
  table_name text not null,
  row_id text not null,
  row_label text,
  action text not null check (action in ('added', 'changed', 'removed')),
  field text,
  old_value text,
  new_value text
);
create index dn_changes_individual_at on mirror.dn_changes (individual_id, at desc);
alter table mirror.dn_changes enable row level security;
revoke all on mirror.dn_changes from public, anon, authenticated;
grant select, insert, delete on mirror.dn_changes to service_role;

create or replace function mirror.dn_change_log() returns trigger
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_email text := lower(auth.email());
  v_ind uuid;
  v_role text;
  v_org uuid;
  o jsonb;
  n jsonb;
  k text;
  v_row text;
  v_label text;
  skip text[] := array['id', 'individual_id', 'created_at', 'updated_at'];
begin
  if v_email is null then return null; end if;
  if tg_op = 'DELETE' then v_ind := old.individual_id; else v_ind := new.individual_id; end if;
  if not exists (select 1 from mirror.individuals i where i.id = v_ind) then return null; end if;            -- the person is being deleted
  if exists (select 1 from mirror.individuals i where i.id = v_ind and i.auth_email = v_email) then return null; end if;   -- their own edit
  select om.role, om.organization_id into v_role, v_org
  from mirror.organization_members om
  join mirror.organizations og on og.id = om.organization_id and og.active
  join mirror.organization_individuals oi on oi.organization_id = om.organization_id and oi.individual_id = v_ind and oi.status = 'active'
  where om.auth_email = v_email and om.active
  order by case om.role when 'org_admin' then 1 when 'coordinator' then 2 else 3 end
  limit 1;
  v_role := coalesce(v_role, 'other');
  if tg_op <> 'INSERT' then o := to_jsonb(old) - skip; end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new) - skip; end if;
  if tg_table_name = 'daily_number_settings' then v_row := v_ind::text;
  elsif tg_op = 'DELETE' then v_row := old.id::text; else v_row := new.id::text; end if;
  v_label := coalesce(n ->> 'label', o ->> 'label', n ->> 'program', o ->> 'program', case when tg_table_name = 'daily_number_settings' then 'Settings' end);
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if (o -> k) is distinct from (n -> k) then
        insert into mirror.dn_changes (individual_id, actor_email, actor_role, organization_id, table_name, row_id, row_label, action, field, old_value, new_value)
        values (v_ind, v_email, v_role, v_org, tg_table_name, v_row, v_label, 'changed', k, o ->> k, n ->> k);
      end if;
    end loop;
  elsif tg_op = 'INSERT' then
    insert into mirror.dn_changes (individual_id, actor_email, actor_role, organization_id, table_name, row_id, row_label, action, new_value)
    values (v_ind, v_email, v_role, v_org, tg_table_name, v_row, v_label, 'added', jsonb_strip_nulls(n)::text);
  else
    insert into mirror.dn_changes (individual_id, actor_email, actor_role, organization_id, table_name, row_id, row_label, action, old_value)
    values (v_ind, v_email, v_role, v_org, tg_table_name, v_row, v_label, 'removed', jsonb_strip_nulls(o)::text);
  end if;
  return null;
end $$;
revoke all on function mirror.dn_change_log() from public, anon, authenticated;

create trigger living_expenses_change_log after insert or update or delete on mirror.living_expenses for each row execute function mirror.dn_change_log();
create trigger income_sources_change_log after insert or update or delete on mirror.income_sources for each row execute function mirror.dn_change_log();
create trigger noncash_resources_change_log after insert or update or delete on mirror.noncash_resources for each row execute function mirror.dn_change_log();
create trigger financial_goals_change_log after insert or update or delete on mirror.financial_goals for each row execute function mirror.dn_change_log();
create trigger daily_number_settings_change_log after insert or update or delete on mirror.daily_number_settings for each row execute function mirror.dn_change_log();
create trigger household_members_change_log after insert or update or delete on mirror.household_members for each row execute function mirror.dn_change_log();
create trigger benefit_records_change_log after insert or update or delete on mirror.benefit_records for each row execute function mirror.dn_change_log();
create trigger income_opportunities_change_log after insert or update or delete on mirror.income_opportunities for each row execute function mirror.dn_change_log();

-- The list as the person (or a helper allowed to view the money topic) sees it: newest first, staff named, never their email.
create or replace function mirror.dn_changes_list(p_individual uuid) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', c.at,
      'who', coalesce(om.name, 'Someone at ' || coalesce(og.name, 'an organization')),
      'organization', og.name,
      'role', c.actor_role,
      'list', c.table_name,
      'row_id', c.row_id,
      'label', c.row_label,
      'action', c.action,
      'field', c.field,
      'from', c.old_value,
      'to', c.new_value) order by c.at desc, c.id desc), '[]'::jsonb)
  from (select * from mirror.dn_changes where individual_id = p_individual order by at desc, id desc limit 500) c
  left join mirror.organizations og on og.id = c.organization_id
  left join mirror.organization_members om on om.organization_id = c.organization_id and om.auth_email = c.actor_email;
$$;
revoke all on function mirror.dn_changes_list(uuid) from public, anon, authenticated;
grant execute on function mirror.dn_changes_list(uuid) to service_role;

create or replace function public.mirror_dn_changes(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb;
begin
  r := mirror.allowed(v, 'financial', 'view', null, 'dn_changes', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  return mirror.dn_changes_list(v);
end $$;
revoke all on function public.mirror_dn_changes(uuid) from public, anon;
grant execute on function public.mirror_dn_changes(uuid) to authenticated, service_role;

-- The download: live body (11/13/2026) + 'changes' under daily_number.
CREATE OR REPLACE FUNCTION public.mirror_my_export()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
      'plan', mirror.dn_plan(v),
      'changes', mirror.dn_changes_list(v),
      'saved', coalesce((select jsonb_agg(jsonb_build_object('taken_at', s.taken_at, 'note', s.note, 'by', s.taken_by_role, 'inputs', s.inputs, 'results', s.results)
          order by s.taken_at) from mirror.daily_number_snapshots s where s.individual_id = v), '[]'::jsonb)),
    'who_looked', public.mirror_who_looked());
  perform mirror.audit(v, null, 'self', 'export', 'general', 'individuals', null);
  return r;
end $function$;
