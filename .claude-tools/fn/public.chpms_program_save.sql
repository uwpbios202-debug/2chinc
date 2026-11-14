CREATE OR REPLACE FUNCTION public.chpms_program_save(p jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := chpms_require(true); v_id text := nullif(trim(p->>'program_id'), ''); o chpms_programs; n chpms_programs; v_changed text[] := '{}';
        v_assist_before text; v_pops_before text;
begin
  if v_role <> 'staff' then raise exception 'Only the office edits the directory. Use "Log a check" to report what you found out.' using errcode = '42501'; end if;
  if coalesce(trim(p->>'program_name'), '') = '' then raise exception 'The program''s name is required.'; end if;
  if coalesce(p->>'verification_status', 'Needs Confirmation') not in ('Verified – Current', 'Verified – Limited', 'Verified – Limited (imported)', 'Needs Confirmation', 'Unverified Lead', 'Inactive/Expired') then
    raise exception 'Unknown verification status'; end if;
  if v_id is null then
    if not exists (select 1 from chpms_orgs where org_id = p->>'org_id') then raise exception 'Organization not found.'; end if;
    v_id := 'L-PRG' || lpad(nextval('chpms_local_seq')::text, 3, '0');
    insert into chpms_programs (program_id, org_id, program_name, is_local, provenance, date_accessed) values (v_id, p->>'org_id', trim(p->>'program_name'), true, 'Added by the office', current_date);
    insert into chpms_program_assist (program_id, category, provided)
      select v_id, c, false from unnest(array['Emergency rental assistance', 'Monthly rental assistance', 'Security deposit assistance', 'First month''s rent',
        'Last month''s rent', 'Eviction prevention', 'Utility assistance', 'Moving expenses', 'Furniture and household items', 'Transitional housing',
        'Permanent housing', 'Housing vouchers', 'Rapid rehousing', 'Supportive housing', 'Case management', 'Housing navigation', 'Landlord mediation',
        'Financial counseling', 'Benefits enrollment', 'Other housing support']) c;
  end if;
  select * into o from chpms_programs where program_id = v_id;
  if o.program_id is null then raise exception 'Program not found.'; end if;
  select string_agg(category, ',' order by category) into v_assist_before from chpms_program_assist where program_id = v_id and provided;
  select string_agg(population, ',' order by population) into v_pops_before from chpms_program_pops where program_id = v_id;
  update chpms_programs set
    program_name = trim(p->>'program_name'), assistance_form = nullif(trim(p->>'assistance_form'), ''), payment_goes_to = nullif(trim(p->>'payment_goes_to'), ''),
    max_assistance = nullif(trim(p->>'max_assistance'), ''), months_covered = nullif(trim(p->>'months_covered'), ''), frequency = nullif(trim(p->>'frequency'), ''),
    current_status = nullif(trim(p->>'current_status'), ''), waiting_list = nullif(trim(p->>'waiting_list'), ''), application_window = nullif(trim(p->>'application_window'), ''),
    income_limits = nullif(trim(p->>'income_limits'), ''), eligibility_summary = nullif(trim(p->>'eligibility_summary'), ''), how_to_apply = nullif(trim(p->>'how_to_apply'), ''),
    referral_requirement = nullif(trim(p->>'referral_requirement'), ''), application_url = nullif(trim(p->>'application_url'), ''), intake_phone = nullif(trim(p->>'intake_phone'), ''),
    is_direct_financial = coalesce((p->>'is_direct_financial')::boolean, is_direct_financial),
    verification_status = coalesce(nullif(p->>'verification_status', ''), verification_status), notes = nullif(trim(p->>'notes'), ''),
    our_note = nullif(trim(p->>'our_note'), ''), updated_at = now()
  where program_id = v_id returning * into n;
  if p ? 'assist' then
    update chpms_program_assist set provided = category in (select jsonb_array_elements_text(p->'assist')) where program_id = v_id;
  end if;
  if p ? 'pops' then
    delete from chpms_program_pops where program_id = v_id;
    insert into chpms_program_pops (program_id, population) select v_id, x from jsonb_array_elements_text(p->'pops') x on conflict do nothing;
  end if;
  select array_agg(k) into v_changed from jsonb_each(to_jsonb(n)) e(k, v)
   where k in ('program_name', 'assistance_form', 'payment_goes_to', 'max_assistance', 'months_covered', 'frequency', 'current_status', 'waiting_list',
               'application_window', 'income_limits', 'eligibility_summary', 'how_to_apply', 'referral_requirement', 'application_url', 'intake_phone',
               'is_direct_financial', 'verification_status', 'notes') and v is distinct from to_jsonb(o)->k;
  if coalesce((select string_agg(category, ',' order by category) from chpms_program_assist where program_id = v_id and provided), '') <> coalesce(v_assist_before, '') then
    v_changed := array_append(coalesce(v_changed, '{}'), 'kinds of help'); end if;
  if coalesce((select string_agg(population, ',' order by population) from chpms_program_pops where program_id = v_id), '') <> coalesce(v_pops_before, '') then
    v_changed := array_append(coalesce(v_changed, '{}'), 'who it serves'); end if;
  if coalesce(array_length(v_changed, 1), 0) > 0 then
    update chpms_programs set staff_edited_at = now(), staff_edited_by = chpms_my_name() where program_id = v_id;
    insert into chpms_checks (record_type, record_id, status, method, notes, by_email, by_name, by_role)
    values ('program', v_id, n.verification_status, 'Office edit', 'Changed: ' || array_to_string(v_changed, ', '), lower(auth.email()), chpms_my_name(), 'staff');
  end if;
  return v_id;
end $function$

