CREATE OR REPLACE FUNCTION public.mirror_whoami()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
declare
  v_email text := lower(auth.email());
  v_aal text := coalesce(auth.jwt() ->> 'aal', '');
  v_person jsonb;
  v_member jsonb;
  v_invites int := 0;
  v_state text;
begin
  if v_email is null then return jsonb_build_object('signed_in', false); end if;
  -- a device past its Mirror limits (or signed out everywhere) counts as signed out: the page asks for a new code.
  -- A coordinator's screen lock is not signed out: the page asks for the authenticator code only.
  v_state := mirror.session_state();
  if v_state <> 'ok' and v_state <> 'locked' then return jsonb_build_object('signed_in', false, 'expired', true); end if;
  select jsonb_build_object('id', i.id, 'preferred_name', i.preferred_name) into v_person
    from mirror.individuals i where i.auth_email = v_email;
  select jsonb_agg(jsonb_build_object('organization_id', o.id, 'organization', o.name, 'role', m.role, 'name', m.name) order by o.name) into v_member
    from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active
    where m.auth_email = v_email and m.active;
  if v_person is not null then
    select count(*) into v_invites from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
     where oi.individual_id = (v_person ->> 'id')::uuid and oi.status = 'invited';
  end if;
  return jsonb_build_object(
    'signed_in', true,
    'locked', v_state = 'locked',
    'session', jsonb_build_object('device', mirror.session_device(), 'limits', mirror.session_limits()),
    'email', v_email,
    'aal', v_aal,
    'view_as', public.autopay_view_as_session(),
    'person', v_person,
    'memberships', coalesce(v_member, '[]'::jsonb),
    'needs_authenticator', v_member is not null and v_aal <> 'aal2',
    'invitations', v_invites,
    'signin_enabled', coalesce((select value from public.portal_settings where key = 'mirror_signin_enabled'), 'off') = 'on');
end $function$
;
