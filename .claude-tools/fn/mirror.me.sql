CREATE OR REPLACE FUNCTION mirror.me()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid;
begin
  if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  select id into v from mirror.individuals where auth_email = lower(auth.email());
  if v is null then raise exception 'There is no Mirror for this sign-in.' using errcode = '42501'; end if;
  return v;
end $function$

