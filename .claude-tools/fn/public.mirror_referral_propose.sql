CREATE OR REPLACE FUNCTION public.mirror_referral_propose(p_suggestion uuid, p_org uuid DEFAULT NULL::uuid, p_help text[] DEFAULT NULL::text[], p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  s mirror.resource_suggestions;
  g jsonb;
  v_org uuid;
  o public.chpms_orgs;
  pr public.chpms_programs;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_help text[];
  x mirror.referrals;
begin
  select * into s from mirror.resource_suggestions where id = p_suggestion;
  if not found then raise exception 'That program is not on the list.' using errcode = 'P0002'; end if;
  g := mirror.require(s.individual_id, s.category, 'edit', null, 'referrals', null);
  if (g ->> 'role') = 'self' then
    if p_org is null or not exists (select 1 from mirror.organization_individuals oi join mirror.organizations og on og.id = oi.organization_id and og.active
                                     where oi.individual_id = s.individual_id and oi.organization_id = p_org and oi.status = 'active') then
      raise exception 'Choose an organization you work with to make the referral.' using errcode = '22023';
    end if;
    v_org := p_org;
  else
    v_org := (g ->> 'organization_id')::uuid;
    if p_org is not null and p_org <> v_org then raise exception 'You can propose referrals only for your own organization.' using errcode = '42501'; end if;
  end if;
  if s.chpms_program_id is null then raise exception 'That program is no longer in the directory.' using errcode = 'P0002'; end if;
  select * into pr from public.chpms_programs where program_id = s.chpms_program_id;
  select * into o from public.chpms_orgs where org_id = pr.org_id;
  if o.our_relationship = 'do_not_refer' then
    raise exception 'The office has marked % "Do not refer". Ask the office first.', o.legal_name using errcode = '42501';
  end if;
  if length(coalesce(v_note, '')) > 2000 then raise exception 'The note is too long (2,000 letters at most).' using errcode = '22023'; end if;
  select coalesce(array_agg(distinct h order by h), '{}') into v_help from unnest(coalesce(p_help, '{}')) h
   where h in (select a.category from public.chpms_program_assist a where a.program_id = pr.program_id and a.provided);
  if exists (select 1 from mirror.referrals y where y.individual_id = s.individual_id and y.organization_id = v_org
              and y.chpms_org_id = o.org_id and coalesce(y.chpms_program_id, '') = coalesce(pr.program_id, '')
              and y.status in ('awaiting_consent', 'consented')) then
    raise exception 'A referral to this program is already waiting.' using errcode = '23505';
  end if;
  insert into mirror.referrals (individual_id, organization_id, suggestion_id, chpms_org_id, chpms_program_id, org_name, program_name,
    category, help_needed, note_to_program, proposed_by, proposed_by_role)
  values (s.individual_id, v_org, s.id, o.org_id, pr.program_id, o.legal_name, pr.program_name, s.category, v_help, v_note,
    lower(auth.email()), g ->> 'role')
  returning * into x;
  perform mirror.referral_event(x.id, 'proposed', null, g ->> 'role');
  return mirror.referral_json(x);
end $function$

