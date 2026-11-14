
-- ---------------------------------------------------------------- end dates
-- The active share's end date, or null (helper).
create or replace function mirror.consent_until_check(p_until date) returns void
language plpgsql stable set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  if p_until is not null and (p_until <= current_date or p_until > current_date + interval '5 years') then
    raise exception 'Choose an end date from tomorrow up to 5 years from now, or no end date.' using errcode = '22023';
  end if;
end $$;

-- The person: set or clear the end date of what they share with one organization on one topic.
create or replace function public.mirror_my_consent_until(p_org uuid, p_category text, p_until date) returns void
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v uuid := mirror.me(); n int;
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.consent_until_check(p_until);
  update mirror.consents set expires_on = p_until
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null
     and (expires_on is null or expires_on >= current_date);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You are not sharing that topic with that organization.' using errcode = '22023'; end if;
  perform mirror.audit(v, p_org, 'self', 'consent_until', p_category, 'consents', coalesce(p_until::text, 'no end date'));
end $$;

-- A coordinator records the end date a person without a sign-in gave them (same rules as mirror_consent_record).
create or replace function public.mirror_consent_record_until(p_individual uuid, p_org uuid, p_category text, p_until date) returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare n int;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual and status = 'active') then
    raise exception 'This person is not actively working with your organization.' using errcode = '42501';
  end if;
  if exists (select 1 from mirror.individuals where id = p_individual and auth_email is not null) then
    raise exception 'This person can sign in, so they choose for themselves in their own Settings.' using errcode = '42501';
  end if;
  perform mirror.consent_until_check(p_until);
  update mirror.consents set expires_on = p_until
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null
     and (expires_on is null or expires_on >= current_date);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'They are not sharing that topic with your organization.' using errcode = '22023'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_until', p_category, 'consents', coalesce(p_until::text, 'no end date'));
  return public.mirror_consents_recorded(p_individual, p_org);
end $$;

-- mirror_my_consent_set: live body; NEW: the end date of the share being replaced is kept.
create or replace function public.mirror_my_consent_set(p_org uuid, p_category text, p_access text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); had int; v_until date;
begin
  if p_category not in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents') then
    raise exception 'Unknown topic.' using errcode = '22023';
  end if;
  if p_access not in ('none', 'view', 'edit') then raise exception 'Unknown choice.' using errcode = '22023'; end if;
  if not exists (select 1 from mirror.organization_individuals where individual_id = v and organization_id = p_org and status <> 'ended') then
    raise exception 'You are not working with that organization.' using errcode = '42501';
  end if;
  select expires_on into v_until from mirror.consents                                                   -- NEW
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null
     and expires_on >= (now() at time zone 'America/Chicago')::date order by granted_at desc limit 1;
  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null;
  get diagnostics had = row_count;
  if p_access <> 'none' then
    insert into mirror.consents (individual_id, organization_id, category, access, granted_by, expires_on) values (v, p_org, p_category, p_access, lower(auth.email()), v_until);
    perform mirror.audit(v, p_org, 'self', 'consent_grant', p_category, 'consents', p_access);
  elsif had > 0 then
    perform mirror.audit(v, p_org, 'self', 'consent_revoke', p_category, 'consents', null);
  end if;
end $$;

-- mirror_consent_record: live body; NEW: the end date of the share being replaced is kept.
create or replace function public.mirror_consent_record(p_individual uuid, p_org uuid, p_category text, p_access text, p_method text, p_note text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_had int; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_until date;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual and status = 'active') then
    raise exception 'This person is not actively working with your organization.' using errcode = '42501';
  end if;
  if exists (select 1 from mirror.individuals where id = p_individual and auth_email is not null) then
    raise exception 'This person can sign in, so they choose for themselves in their own Settings.' using errcode = '42501';
  end if;
  if p_category not in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents') then
    raise exception 'Unknown topic.' using errcode = '22023';
  end if;
  if p_access not in ('none', 'view', 'edit') then raise exception 'Unknown choice.' using errcode = '22023'; end if;
  if p_method not in ('paper', 'spoken') then raise exception 'Say how the person agreed: on paper or out loud.' using errcode = '22023'; end if;
  if v_note is null or length(v_note) < 5 then
    raise exception 'Add a short note, for example where the signed form is kept or who was there.' using errcode = '22023';
  end if;
  select expires_on into v_until from mirror.consents                                                   -- NEW
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null
     and expires_on >= (now() at time zone 'America/Chicago')::date order by granted_at desc limit 1;
  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null;
  get diagnostics v_had = row_count;
  if p_access <> 'none' then
    insert into mirror.consents (individual_id, organization_id, category, access, granted_by, method, note, expires_on)
    values (p_individual, p_org, p_category, p_access, lower(auth.email()), p_method, v_note, v_until);
    perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_grant', p_category, 'consents', p_method || ':' || p_access);
  elsif v_had > 0 then
    perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_revoke', p_category, 'consents', p_method);
  end if;
  return public.mirror_consents_recorded(p_individual, p_org);
end $$;

-- mirror_my_settings: live body; NEW: 'sharing_until' (topic -> end date) per organization.
create or replace function public.mirror_my_settings() returns jsonb
language plpgsql stable security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
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
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb),
        'sharing_until', coalesce((select jsonb_object_agg(c.category, c.expires_on) from mirror.consents c          -- NEW
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.expires_on >= current_date), '{}'::jsonb),
        'sharing_detail', coalesce((select jsonb_object_agg(c.category, jsonb_build_object('method', c.method, 'at', c.granted_at,
            'by', coalesce((select m.name from mirror.organization_members m where m.organization_id = o.id and m.auth_email = c.granted_by), 'you'))) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.method <> 'online'
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb))
        order by (oi.status = 'ended'), o.name)
      from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id
      where oi.individual_id = v), '[]'::jsonb));
end $$;

-- mirror_consents_recorded: live body; NEW: 'until' on each share.
create or replace function public.mirror_consents_recorded(p_individual uuid, p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual and status = 'active') then
    raise exception 'This person is not actively working with your organization.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'can_record', (select auth_email is null from mirror.individuals where id = p_individual),
    'sharing', coalesce((select jsonb_object_agg(c.category, jsonb_build_object('access', c.access, 'method', c.method, 'note', c.note, 'at', c.granted_at,
        'until', c.expires_on,                                                                                    -- NEW
        'by', coalesce((select m.name from mirror.organization_members m where m.organization_id = p_org and m.auth_email = c.granted_by), c.granted_by)))
      from mirror.consents c where c.individual_id = p_individual and c.organization_id = p_org and c.revoked_at is null
        and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb));
end $$;

revoke all on function mirror.consent_until_check(date) from public, anon, authenticated;
revoke all on function public.mirror_my_consent_until(uuid, text, date), public.mirror_consent_record_until(uuid, uuid, text, date) from public, anon;
grant execute on function public.mirror_my_consent_until(uuid, text, date), public.mirror_consent_record_until(uuid, uuid, text, date) to authenticated, service_role;
