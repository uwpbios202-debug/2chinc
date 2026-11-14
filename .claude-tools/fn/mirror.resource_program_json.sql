CREATE OR REPLACE FUNCTION mirror.resource_program_json(p_program text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
  select jsonb_build_object('program_id', p.program_id, 'program_name', p.program_name, 'org_name', coalesce(nullif(o.dba, ''), o.legal_name),
    'serves', o.service_area, 'help', coalesce((select jsonb_agg(a.category order by a.category) from public.chpms_program_assist a
       where a.program_id = p.program_id and a.provided), '[]'::jsonb),
    'for', coalesce((select jsonb_agg(pp.population order by pp.population) from public.chpms_program_pops pp where pp.program_id = p.program_id), '[]'::jsonb),
    'who_qualifies', p.eligibility_summary, 'how_to_apply', p.how_to_apply, 'referral', p.referral_requirement,
    'phone', coalesce(nullif(p.intake_phone, ''), o.main_phone), 'link', coalesce(nullif(p.application_url, ''), o.website),
    'checked_on', coalesce(o.our_checked_on, p.date_accessed), 'areas', mirror.program_areas(p.program_id))
    from public.chpms_programs p join public.chpms_orgs o on o.org_id = p.org_id
   where p.program_id = p_program;
$function$

