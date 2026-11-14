-- The Human Mirror T3.6: the person's own privacy controls and settings (Mirror 2: "the Mirror is the individual's own property";
-- SECURITY_PLAN 1.4-1.5, 1.11; D-14, D-18). Every function here acts ONLY on the signed-in person's own Mirror, never in View as.
--   mirror_my_settings()                  profile, organizations, current sharing per topic, deletion state
--   mirror_my_consent_set(org, topic, access)   none | view | edit  (old choice kept as history; audited)
--   mirror_my_org_end(org)                stop working with an organization: all its sharing withdrawn, link ended
--   mirror_my_profile_save(p)             name they go by, legal name, birth year
--   mirror_my_safety(on)                  safety mode
--   mirror_my_export()                    everything about the person (answers, earlier answers, sharing, who looked)
--   mirror_my_deletion(request)           ask to delete (30-day hold, D-18) or cancel the request

create or replace function mirror.me() returns uuid
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid;
begin
  if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  select id into v from mirror.individuals where auth_email = lower(auth.email());
  if v is null then raise exception 'There is no Mirror for this sign-in.' using errcode = '42501'; end if;
  return v;
end $$;

create or replace function public.mirror_my_settings() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return jsonb_build_object(
    'person', (select jsonb_build_object('preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'birth_year', i.birth_year,
        'email', i.auth_email, 'safety_sensitive', i.safety_sensitive, 'deletion_requested_at', i.deletion_requested_at,
        'deletion_on', (i.deletion_requested_at + interval '30 days')::date)
      from mirror.individuals i where i.id = v),
    'organizations', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'kind', o.kind, 'status', oi.status, 'started_on', oi.started_on,
        'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
        'sharing', coalesce((select jsonb_object_agg(c.category, c.access) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb))
        order by (oi.status = 'ended'), o.name)
      from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id
      where oi.individual_id = v), '[]'::jsonb));
end $$;

create or replace function public.mirror_my_consent_set(p_org uuid, p_category text, p_access text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); had int;
begin
  if p_category not in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents') then
    raise exception 'Unknown topic.' using errcode = '22023';
  end if;
  if p_access not in ('none', 'view', 'edit') then raise exception 'Unknown choice.' using errcode = '22023'; end if;
  if not exists (select 1 from mirror.organization_individuals where individual_id = v and organization_id = p_org and status <> 'ended') then
    raise exception 'You are not working with that organization.' using errcode = '42501';
  end if;
  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null;
  get diagnostics had = row_count;
  if p_access <> 'none' then
    insert into mirror.consents (individual_id, organization_id, category, access, granted_by) values (v, p_org, p_category, p_access, lower(auth.email()));
    perform mirror.audit(v, p_org, 'self', 'consent_grant', p_category, 'consents', p_access);
  elsif had > 0 then
    perform mirror.audit(v, p_org, 'self', 'consent_revoke', p_category, 'consents', null);
  end if;
end $$;

create or replace function public.mirror_my_org_end(p_org uuid) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  update mirror.organization_individuals set status = 'ended', ended_on = current_date
   where individual_id = v and organization_id = p_org and status <> 'ended';
  if not found then raise exception 'You are not working with that organization.' using errcode = 'P0002'; end if;
  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = v and organization_id = p_org and revoked_at is null;
  perform mirror.audit(v, p_org, 'self', 'org_end', 'general', 'organization_individuals', null);
end $$;

create or replace function public.mirror_my_profile_save(p jsonb) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); v_year int := nullif(p ->> 'birth_year', '')::int;
begin
  if nullif(btrim(p ->> 'preferred_name'), '') is null then raise exception 'Enter the name you go by.' using errcode = '22023'; end if;
  if v_year is not null and (v_year < 1900 or v_year > extract(year from now())::int) then raise exception 'Birth year looks wrong.' using errcode = '22023'; end if;
  update mirror.individuals set preferred_name = btrim(p ->> 'preferred_name'), legal_name = nullif(btrim(p ->> 'legal_name'), ''), birth_year = v_year
   where id = v;
end $$;

create or replace function public.mirror_my_safety(p_on boolean) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  update mirror.individuals set safety_sensitive = coalesce(p_on, false) where id = v;
  perform mirror.audit(v, null, 'self', case when p_on then 'safety_on' else 'safety_off' end, 'safety_flag', 'individuals', null);
end $$;

-- Everything about the person, for them to keep or take elsewhere. Logged as an export (ids only).
create or replace function public.mirror_my_export() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
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
    'answers', coalesce((select jsonb_agg(jsonb_build_object('set', s.title, 'set_key', s.key, 'question', q.prompt, 'question_key', q.key,
        'answer', x.value, 'state', x.state, 'note', x.note, 'by', x.answered_by_role, 'at', x.answered_at, 'current', x.superseded_at is null)
        order by s.kind, s.sort, q.sort, x.answered_at)
      from mirror.assessment_responses x join mirror.assessments a on a.id = x.assessment_id
      join mirror.question_sets s on s.id = a.set_id join mirror.reflection_questions q on q.id = x.question_id
      where a.individual_id = v), '[]'::jsonb),
    'who_looked', public.mirror_who_looked());
  perform mirror.audit(v, null, 'self', 'export', 'general', 'individuals', null);
  return r;
end $$;

-- D-18: a request starts a 30-day hold; the person can cancel it until the platform admin deletes the Mirror.
create or replace function public.mirror_my_deletion(p_request boolean) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  update mirror.individuals set deletion_requested_at = case when p_request then coalesce(deletion_requested_at, now()) end where id = v;
  perform mirror.audit(v, null, 'self', case when p_request then 'delete_request' else 'delete_cancel' end, 'general', 'individuals', null);
  return (select jsonb_build_object('deletion_requested_at', deletion_requested_at, 'deletion_on', (deletion_requested_at + interval '30 days')::date)
          from mirror.individuals where id = v);
end $$;

revoke all on function mirror.me() from public, anon, authenticated;
grant execute on function mirror.me() to service_role;
revoke all on function public.mirror_my_settings(), public.mirror_my_consent_set(uuid, text, text), public.mirror_my_org_end(uuid),
  public.mirror_my_profile_save(jsonb), public.mirror_my_safety(boolean), public.mirror_my_export(), public.mirror_my_deletion(boolean) from public, anon;
grant execute on function public.mirror_my_settings(), public.mirror_my_consent_set(uuid, text, text), public.mirror_my_org_end(uuid),
  public.mirror_my_profile_save(jsonb), public.mirror_my_safety(boolean), public.mirror_my_export(), public.mirror_my_deletion(boolean) to authenticated, service_role;
