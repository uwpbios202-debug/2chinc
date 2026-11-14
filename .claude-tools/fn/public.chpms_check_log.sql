CREATE OR REPLACE FUNCTION public.chpms_check_log(p jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := chpms_require(true); v_type text := p->>'record_type'; v_rec text := p->>'record_id'; v_id bigint;
        v_on date := coalesce(nullif(p->>'checked_on', '')::date, current_date); v_org text;
begin
  if v_type = 'org' then select org_id into v_org from chpms_orgs where org_id = v_rec;
  elsif v_type = 'program' then select org_id into v_org from chpms_programs where program_id = v_rec;
  else raise exception 'Unknown record type'; end if;
  if v_org is null then raise exception 'That organization or program is not in the directory.'; end if;
  if v_on > current_date then raise exception 'The date of the check cannot be in the future.'; end if;
  if v_on < current_date - 60 then raise exception 'Log checks within 60 days of making them.'; end if;
  if nullif(p->>'result', '') is null then raise exception 'Choose what you found out.'; end if;
  if length(coalesce(p->>'notes', '')) > 2000 then raise exception 'Notes are too long (2,000 characters at most).'; end if;
  if (select count(*) from chpms_checks where lower(by_email) = lower(auth.email()) and created_at > now() - interval '1 day') >= 100 then
    raise exception 'That is 100 checks in a day; try again tomorrow or ask the office.';
  end if;
  insert into chpms_checks (record_type, record_id, checked_on, result, funds_today, method, notes, by_email, by_name, by_role)
  values (v_type, v_rec, v_on, p->>'result', nullif(p->>'funds_today', ''), nullif(trim(p->>'method'), ''), nullif(trim(p->>'notes'), ''),
          lower(auth.email()), chpms_my_name(), v_role)
  returning id into v_id;
  if v_role = 'staff' then
    update chpms_orgs set our_checked_on = greatest(coalesce(our_checked_on, v_on), v_on), our_checked_by = chpms_my_name(), updated_at = now() where org_id = v_org;
  end if;
  return v_id;
end $function$

