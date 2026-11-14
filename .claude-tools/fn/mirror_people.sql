CREATE OR REPLACE FUNCTION public.mirror_people(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(case when mirror.known_to_org(i.id, p_org) then jsonb_build_object(
      'id', i.id, 'preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'email', i.auth_email, 'birth_year', i.birth_year,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', i.safety_sensitive)
    else jsonb_build_object(
      'id', i.id, 'preferred_name', coalesce(oi.invited_name, 'Invited person'), 'legal_name', null, 'email', i.auth_email, 'birth_year', null,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', null) end
    order by (oi.status = 'ended'), lower(case when mirror.known_to_org(i.id, p_org) then i.preferred_name else coalesce(oi.invited_name, '') end))
    from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
    where oi.organization_id = p_org), '[]'::jsonb);
end $function$
;
