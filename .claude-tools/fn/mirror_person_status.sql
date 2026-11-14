CREATE OR REPLACE FUNCTION public.mirror_person_status(p_org uuid, p_individual uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
 SET "TimeZone" TO 'America/Chicago'
AS $function$
declare v_email text;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if p_status not in ('ended', 'active', 'invited') then raise exception 'Unknown status.' using errcode = '22023'; end if;
  select auth_email into v_email from mirror.individuals where id = p_individual;
  if p_status = 'active' and v_email is not null then
    raise exception 'This person has their own sign-in, so they say yes themselves on My Mirror. Invite them instead.' using errcode = '42501';
  end if;
  if p_status = 'invited' and v_email is null then
    raise exception 'This person has no email, so there is no invitation to send. Restart them instead.' using errcode = '22023';
  end if;
  update mirror.organization_individuals
     set status = p_status, ended_on = case when p_status = 'ended' then current_date else null end
   where organization_id = p_org and individual_id = p_individual;
  if not found then raise exception 'This person is not on your list.' using errcode = 'P0002'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'edit', 'general', 'organization_individuals', p_status);
end $function$
;
