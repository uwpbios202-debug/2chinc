CREATE OR REPLACE FUNCTION public.mirror_org_audit(p_org uuid, p_before bigint DEFAULT NULL::bigint, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v_rows jsonb;
begin
  if not mirror.i_can(p_org, 'audit', 'view') then
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
end $function$
;
