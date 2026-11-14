CREATE OR REPLACE FUNCTION public.chpms_referral_save(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := chpms_require(true); v_id uuid := nullif(p->>'id', '')::uuid; r chpms_referrals; o chpms_orgs; pr chpms_programs;
        v_nav uuid := nullif(p->>'nav_referral_id', '')::uuid; v_help text[]; v_new boolean := false;
begin
  select * into o from chpms_orgs where org_id = p->>'org_id';
  if o.org_id is null then raise exception 'Pick the organization you are referring to.'; end if;
  if nullif(p->>'program_id', '') is not null then
    select * into pr from chpms_programs where program_id = p->>'program_id' and org_id = o.org_id;
    if pr.program_id is null then raise exception 'That program does not belong to this organization.'; end if;
  end if;
  if o.our_relationship = 'do_not_refer' then raise exception 'The office has marked % "Do not refer". Ask the office first.', o.legal_name; end if;
  if coalesce(trim(p->>'first_name'), '') = '' or coalesce(trim(p->>'last_name'), '') = '' then raise exception 'First and last name are required.'; end if;
  if coalesce(trim(p->>'phone'), '') = '' and coalesce(trim(p->>'email'), '') = '' then raise exception 'Give a phone number or an email so the program can reach the person.'; end if;
  if coalesce(trim(p->>'email'), '') <> '' and trim(p->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true or coalesce(trim(p->>'consent_name'), '') = '' then
    raise exception 'The person must agree to the referral and type their own name.';
  end if;
  if length(coalesce(p->>'notes', '')) > 2000 then raise exception 'Notes are too long (2,000 characters at most).'; end if;
  select coalesce(array_agg(x), '{}') into v_help from jsonb_array_elements_text(coalesce(p->'help_needed', '[]'::jsonb)) x
   where x in ('Emergency rental assistance', 'Monthly rental assistance', 'Security deposit assistance', 'First month''s rent', 'Last month''s rent',
               'Eviction prevention', 'Utility assistance', 'Moving expenses', 'Furniture and household items', 'Transitional housing', 'Permanent housing',
               'Housing vouchers', 'Rapid rehousing', 'Supportive housing', 'Case management', 'Housing navigation', 'Landlord mediation',
               'Financial counseling', 'Benefits enrollment', 'Other housing support');
  if v_nav is not null then
    if v_role = 'navigator' and not exists (select 1 from nav_referrals where id = v_nav and navigator_id = nav_me()) then raise exception 'That person is not one of yours.'; end if;
    if v_role = 'field' then v_nav := null; end if;
  end if;
  if v_id is null then
    if (select count(*) from chpms_referrals where lower(made_by_email) = lower(auth.email()) and created_at > now() - interval '1 day') >= 30 then
      raise exception 'That is 30 referrals in a day; ask the office if you need more.';
    end if;
    insert into chpms_referrals (org_id, program_id, org_name, program_name, made_by_email, made_by_name, made_by_role, navigator_id, nav_referral_id,
                                 first_name, last_name, consent_name, consent_on)
    values (o.org_id, pr.program_id, o.legal_name, pr.program_name, lower(auth.email()), chpms_my_name(), v_role,
            case when v_role = 'navigator' then nav_me() else (select navigator_id from nav_referrals where id = v_nav) end, v_nav,
            trim(p->>'first_name'), trim(p->>'last_name'), trim(p->>'consent_name'), current_date)
    returning id into v_id;
    v_new := true;
  end if;
  select * into r from chpms_referrals where id = v_id;
  if r.id is null or not chpms_ref_can(r) then raise exception 'Not found.' using errcode = '42501'; end if;
  if not v_new and r.status <> 'new' then raise exception 'This referral has been sent; add a note instead of changing it.'; end if;
  update chpms_referrals set org_id = o.org_id, program_id = pr.program_id, org_name = o.legal_name, program_name = pr.program_name,
    nav_referral_id = coalesce(v_nav, nav_referral_id),
    first_name = trim(p->>'first_name'), last_name = trim(p->>'last_name'), phone = nullif(trim(p->>'phone'), ''), email = nullif(lower(trim(p->>'email')), ''),
    household_size = nullif(p->>'household_size', '')::int, population = nullif(trim(p->>'population'), ''), help_needed = v_help,
    notes = nullif(trim(p->>'notes'), ''), consent_name = trim(p->>'consent_name'),
    status_checked_on = nullif(p->>'status_checked_on', '')::date, updated_at = now()
  where id = v_id;
  perform chpms_ref_event(v_id, case when v_new then 'created' else 'edited' end,
    o.legal_name || coalesce(' / ' || pr.program_name, '') || case when v_new then '. Consent given by ' || trim(p->>'consent_name') || ' on ' || to_char(current_date, 'MM/DD/YYYY') else '' end);
  if v_new and r.nav_referral_id is not null then
    perform nav_log('outside_referral', 'Referred to ' || o.legal_name || coalesce(' / ' || pr.program_name, '') || ' (resource directory referral #' || r.ref_no || ')', r.nav_referral_id);
  end if;
  -- The office hears about referrals made by field staff and Navigators (no phone or email of the person in the email).
  if v_new and v_role <> 'staff' then
    perform nav_email('info@2ndchinc.org', 'Resource referral #' || r.ref_no || ': ' || o.legal_name,
      '<p>' || repair_esc(chpms_my_name()) || ' (' || case v_role when 'navigator' then 'Housing Navigator' else 'field staff' end || ') referred '
      || repair_esc(trim(p->>'first_name')) || ' ' || repair_esc(left(trim(p->>'last_name'), 1)) || '. to <b>' || repair_esc(o.legal_name) || '</b>'
      || coalesce(' (' || repair_esc(pr.program_name) || ')', '') || '.</p>'
      || case when cardinality(v_help) > 0 then '<p>Help needed: ' || repair_esc(array_to_string(v_help, ', ')) || '</p>' else '' end
      || '<p>Open it at <a href="https://2ndchinc.org/staff/resources/#referrals/' || v_id || '">https://2ndchinc.org/staff/resources/#referrals/' || v_id || '</a></p>',
      'chpms_referral');
  end if;
  return v_id;
end $function$
