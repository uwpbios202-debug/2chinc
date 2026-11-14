CREATE OR REPLACE FUNCTION public.chpms_role()
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if staff_session_staff() then return 'staff'; end if;
  if condo_session_ok() and field_is_staff() then return 'field'; end if;
  if nav_me() is not null then
    return case when exists (select 1 from navigators where id = nav_me() and status = 'preview') then 'navigator_preview' else 'navigator' end;
  end if;
  return null;
end $function$

