CREATE OR REPLACE FUNCTION public.mirror_resource_save(p_program text, p_need uuid DEFAULT NULL::uuid, p_individual uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_id uuid := mirror.target_individual(p_individual);
  n mirror.needs;
  p record;
  v_dim text;
  v_cat text;
  g jsonb;
  s mirror.resource_suggestions;
begin
  select pr.program_id, pr.program_name, coalesce(nullif(o.dba, ''), o.legal_name) org_name, o.our_relationship
    into p from public.chpms_programs pr join public.chpms_orgs o on o.org_id = pr.org_id where pr.program_id = p_program;
  if not found then raise exception 'That program is not in the directory.' using errcode = 'P0002'; end if;
  if coalesce(p.our_relationship, '') = 'do_not_refer' then
    raise exception 'That program cannot be suggested.' using errcode = '42501';
  end if;
  if p_need is not null then
    select * into n from mirror.needs where id = p_need and individual_id = v_id;
    if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
    v_dim := n.dimension_key;
  else
    select rc.dimension_key into v_dim from mirror.resource_categories rc join mirror.dimensions d on d.key = rc.dimension_key
     where rc.chpms_program_id = p_program order by d.n limit 1;
  end if;
  v_cat := mirror.resource_category(p_need, v_dim);
  g := mirror.require(v_id, v_cat, 'edit', null, 'resource_suggestions', null);
  if exists (select 1 from mirror.resource_suggestions x where x.individual_id = v_id and x.chpms_program_id = p_program) then
    raise exception 'That program is already on the list.' using errcode = '23505';
  end if;
  insert into mirror.resource_suggestions (individual_id, chpms_program_id, program_name, org_name, need_id, dimension_key, category,
    source, added_by, added_by_role)
  values (v_id, p.program_id, p.program_name, p.org_name, p_need, v_dim, v_cat,
    case when g ->> 'role' = 'self' then 'match' else 'coordinator' end, lower(auth.email()), g ->> 'role')
  returning * into s;
  insert into mirror.resource_suggestion_events (suggestion_id, from_status, to_status, by_email, by_role)
  values (s.id, null, 'suggested', lower(auth.email()), g ->> 'role');
  return mirror.resource_suggestion_json(s);
end $function$

