== mirror_consent_record
CREATE OR REPLACE FUNCTION public.mirror_consent_record(p_individual uuid, p_org uuid, p_category text, p_access text, p_method text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_had int; v_note text := nullif(btrim(coalesce(p_note, '')), '');
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

  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null;
  get diagnostics v_had = row_count;
  if p_access <> 'none' then
    insert into mirror.consents (individual_id, organization_id, category, access, granted_by, method, note)
    values (p_individual, p_org, p_category, p_access, lower(auth.email()), p_method, v_note);
    perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_grant', p_category, 'consents', p_method || ':' || p_access);
  elsif v_had > 0 then
    perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_revoke', p_category, 'consents', p_method);
  end if;
  return public.mirror_consents_recorded(p_individual, p_org);
end $function$

== mirror_my_consent_set
CREATE OR REPLACE FUNCTION public.mirror_my_consent_set(p_org uuid, p_category text, p_access text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
end $function$

== mirror_my_settings
CREATE OR REPLACE FUNCTION public.mirror_my_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
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
        'sharing_detail', coalesce((select jsonb_object_agg(c.category, jsonb_build_object('method', c.method, 'at', c.granted_at,
            'by', coalesce((select m.name from mirror.organization_members m where m.organization_id = o.id and m.auth_email = c.granted_by), 'you'))) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.method <> 'online'
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb))
        order by (oi.status = 'ended'), o.name)
      from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id
      where oi.individual_id = v), '[]'::jsonb));
end $function$

