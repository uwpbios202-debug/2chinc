CREATE OR REPLACE FUNCTION public.chpms_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := chpms_require(false);
begin
  return jsonb_build_object(
    'role', v_role,
    'can_edit', v_role = 'staff',
    'can_act', v_role in ('staff', 'field', 'navigator') and not autopay_view_as_session(),
    'view_as', autopay_view_as_session(),
    'version', condo_setting('chpms_version', ''),
    'readme', condo_setting('chpms_readme', ''),
    'orgs', coalesce((select jsonb_agg(to_jsonb(o) - 'staff_edited_by' - 'our_checked_by' || jsonb_build_object(
        'last_check', (select chpms_check_json(c) from chpms_checks c where c.record_type = 'org' and c.record_id = o.org_id and not c.from_import
                        order by c.checked_on desc, c.id desc limit 1),
        'programs', coalesce((select jsonb_agg(to_jsonb(p) - 'staff_edited_by' || jsonb_build_object(
            'assist', coalesce((select jsonb_agg(a.category order by a.category) from chpms_program_assist a where a.program_id = p.program_id and a.provided), '[]'::jsonb),
            'pops', coalesce((select jsonb_agg(x.population order by x.population) from chpms_program_pops x where x.program_id = p.program_id), '[]'::jsonb),
            'eligibility', coalesce((select jsonb_agg(jsonb_build_object('type', e.requirement_type, 'requirement', e.requirement, 'source', e.source_id) order by e.elig_id)
                                     from chpms_eligibility e where e.program_id = p.program_id), '[]'::jsonb),
            'last_check', (select chpms_check_json(c) from chpms_checks c where c.record_type = 'program' and c.record_id = p.program_id and not c.from_import
                            order by c.checked_on desc, c.id desc limit 1))
            order by p.program_name) from chpms_programs p where p.org_id = o.org_id), '[]'::jsonb),
        'contacts', coalesce((select jsonb_agg(to_jsonb(k) order by k.contact_id) from chpms_contacts k where k.org_id = o.org_id), '[]'::jsonb),
        'landlord', (select to_jsonb(l) from chpms_landlord l where l.org_id = o.org_id),
        'links_out', coalesce((select jsonb_agg(jsonb_build_object('org_id', r.to_org, 'relationship', r.relationship, 'source_ids', r.source_ids) order by r.rel_id)
                               from chpms_org_links r where r.from_org = o.org_id), '[]'::jsonb),
        'links_in', coalesce((select jsonb_agg(jsonb_build_object('org_id', r.from_org, 'relationship', r.relationship, 'source_ids', r.source_ids) order by r.rel_id)
                              from chpms_org_links r where r.to_org = o.org_id), '[]'::jsonb))
      order by o.legal_name) from chpms_orgs o), '[]'::jsonb),
    'sources', coalesce((select jsonb_object_agg(s.source_id, jsonb_build_object('title', s.title, 'url', s.url, 'publisher', s.publisher, 'type', s.source_type))
                         from chpms_sources s), '{}'::jsonb),
    'my_people', case when v_role = 'navigator' then coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', trim(r.first_name || ' ' || coalesce(r.last_name, '')),
        'phone', r.phone, 'email', r.email, 'household_size', r.household_size, 'veteran', r.veteran) order by r.first_name)
        from nav_referrals r where r.navigator_id = nav_me() and r.status <> 'closed' and r.consent_withdrawn_on is null), '[]'::jsonb) else '[]'::jsonb end
  );
end $function$

