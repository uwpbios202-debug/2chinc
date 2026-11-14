CREATE OR REPLACE FUNCTION public.chpms_require(p_write boolean)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text := chpms_role();
begin
  if v is null then raise exception 'Staff or Housing Navigator sign-in required' using errcode = '42501'; end if;
  if p_write then
    if v = 'navigator_preview' then
      raise exception 'Preview only: you can look around now. Logging checks and referring people opens once the partner and confidentiality agreements are signed.' using errcode = '42501';
    end if;
    if autopay_view_as_session() then raise exception 'Not while viewing as someone else.' using errcode = '42501'; end if;
  end if;
  return v;
end $function$

