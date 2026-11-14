CREATE OR REPLACE FUNCTION public.mirror_my_deletion(p_request boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare v uuid := mirror.me();
begin
  update mirror.individuals set deletion_requested_at = case when p_request then coalesce(deletion_requested_at, now()) end where id = v;
  perform mirror.audit(v, null, 'self', case when p_request then 'delete_request' else 'delete_cancel' end, 'general', 'individuals', null);
  return (select jsonb_build_object('deletion_requested_at', deletion_requested_at, 'deletion_on', (deletion_requested_at + interval '30 days')::date)
          from mirror.individuals where id = v);
end $function$
;
