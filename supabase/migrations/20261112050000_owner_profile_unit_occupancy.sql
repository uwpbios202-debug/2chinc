-- The owner portal needs each unit's occupancy to hide the Guests tab for owner-occupied and vacant units (Stephen, 10/12/2026).
CREATE OR REPLACE FUNCTION public.condo_my_profile()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v jsonb;
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  select jsonb_build_object(
    'name', o.name, 'email', o.email, 'alt_email', o.alt_email,
    'phone_mobile', o.phone_mobile, 'phone_home', o.phone_home, 'phone_work', o.phone_work,
    'communications_preference', o.communications_preference,
    'mailing_line1', o.mailing_line1, 'mailing_line2', o.mailing_line2, 'mailing_city', o.mailing_city,
    'mailing_state', o.mailing_state, 'mailing_zip', o.mailing_zip,
    'alt_line1', o.alt_line1, 'alt_line2', o.alt_line2, 'alt_city', o.alt_city, 'alt_state', o.alt_state, 'alt_zip', o.alt_zip,
    'emergency_name', o.emergency_name, 'emergency_phone', o.emergency_phone,
    'last_confirmed_at', o.last_confirmed_at,
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_number', u.unit_number, 'address', u.address, 'pin', u.pin, 'occupancy', u.occupancy,
        'owner_since', s.start_date, 'board_position', s.board_position,
        'fee', s.fee, 'fee_frequency', s.fee_frequency)
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int)
      from condo_ownerships s join condo_units u on u.id = s.unit_id
      where s.owner_id = o.id and s.is_current), '[]'::jsonb)
  ) into v from condo_owners o where o.id = v_owner;
  return v;
end;
$function$
;
