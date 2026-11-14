-- Mirror Phase 11 T11.9 check: directory programs for the whole-person topics (migration 20261119702000). Read-only checks; always rolled back.
do $chk$
declare r text[] := '{}'; ok boolean; n int;
begin
  -- 1. 25 programs and 7 new organizations, office-added, each with a verification status and a source that exists
  select count(*) into n from chpms_programs where program_id like 'P11-PRG%' and is_local and import_version = 't119-11/14';
  ok := n = 25 and (select count(*) from chpms_orgs where org_id like 'P11-ORG%' and is_local) = 7
    and not exists (select 1 from chpms_programs p where p.program_id like 'P11-PRG%' and (p.verification_status not in ('Verified – Current', 'Verified – Limited')
        or not exists (select 1 from chpms_sources s where s.source_id = p.source_ids) or not exists (select 1 from chpms_orgs o where o.org_id = p.org_id)))
    and not exists (select 1 from chpms_programs p where p.program_id like 'P11-PRG%' and p.verification_status = 'Verified – Limited' and p.notes not like 'Verified – Limited:%');
  r := r || format('1 programs (%s, 25 expected) with status, source and organization; every Limited one says why: %s', n, ok);

  -- 2. every whole-person topic has programs in its life area
  ok := (select count(*) from mirror.resource_categories c where c.chpms_program_id in ('P11-PRG01','P11-PRG02','P11-PRG03','P11-PRG04','P11-PRG05','P11-PRG06') and c.dimension_key = 'self_care') = 6
    and (select count(*) from mirror.resource_categories c where c.chpms_program_id in ('P11-PRG08','P11-PRG09','P11-PRG10') and c.dimension_key = 'housing') = 3
    and (select count(*) from mirror.resource_categories c where c.chpms_program_id in ('P11-PRG11','P11-PRG12','P11-PRG13','P11-PRG14','P11-PRG15') and c.dimension_key = 'mental_health') = 5
    and (select count(*) from mirror.resource_categories c where c.chpms_program_id in ('P11-PRG16','P11-PRG17','P11-PRG14','P11-PRG15','P11-PRG10') and c.dimension_key = 'identity_legal') = 5
    and exists (select 1 from mirror.resource_categories c where c.chpms_program_id = 'P11-PRG18' and c.dimension_key = 'finances')
    and (select count(*) from mirror.resource_categories c where c.chpms_program_id in ('P11-PRG19','P11-PRG20','P11-PRG21','P11-PRG22','P11-PRG23','P11-PRG24','P11-PRG25') and c.dimension_key = 'relationships') = 7
    and not exists (select 1 from chpms_programs p where p.program_id like 'P11-PRG%' and not exists (select 1 from mirror.resource_categories c where c.chpms_program_id = p.program_id and c.source = 'office'));
  r := r || format('2 each topic has programs in its life area (clothing 6, furniture 3, recovery and grief 5, legal and veterans 5, credit 1, family 7): %s', ok);

  -- 3. the existing organizations were reused, not changed; the paused clinic is marked closed
  ok := (select count(*) from chpms_orgs where org_id in ('ORG001','ORG018','ORG019','ORG024','ORG029','ORG030','ORG035','ORG044','ORG052','ORG064','ORG088','ORG098','ORG113')
         and coalesce(import_version, '') <> 't119-11/14') = 13
    and (select current_status like 'Paused%' and currently_open like 'No%' from chpms_programs where program_id = 'P11-PRG16')
    and (select is_direct_financial from chpms_programs where program_id = 'P11-PRG23') and not (select is_direct_financial from chpms_programs where program_id = 'P11-PRG20');
  r := r || format('3 existing organizations reused unchanged; paused clinic marked; money flags right: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
