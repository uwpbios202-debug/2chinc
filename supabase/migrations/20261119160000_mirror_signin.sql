-- The Human Mirror T2.4: sign-in for Mirror people and coordinators WITHOUT changing what anyone else has (Stephen, 11/13/2026:
-- "We do not want to disturb what is in place now for everyone"; option 3 chosen).
--
--  * condo_email_on_file() is NOT changed. View as (admin-view-as) keeps using it, so Mirror-only people never appear there (D-12).
--  * New public.signin_email_on_file() = condo_email_on_file() OR mirror.email_on_file(). Only the code mailer (auth-send-email)
--    calls it, and it falls back to condo_email_on_file() if this function ever errors. It can only ADD Mirror emails: for
--    everyone else the answer is exactly what it was.
--  * Switch portal_settings.mirror_signin_enabled, 'off' until Stephen turns it on. While off, nothing changes for anyone.
--  * mfa_required(), mfa_required_roles, session_role() and the session day settings are not changed. Mirror coordinators must
--    enter an authenticator code because the Mirror's own gate (mirror.allowed) refuses them without it.
--  * public.mirror_whoami(): what the Mirror's own sign-in page needs to know about the signed-in person.

insert into portal_settings (key, value) values ('mirror_signin_enabled', 'off') on conflict (key) do nothing;

-- Who the Mirror itself lets in: a person linked to an organization (invited or active), or an active member of an active
-- organization. Nobody when the switch is off.
create or replace function mirror.email_on_file(p_email text) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce((select value from public.portal_settings where key = 'mirror_signin_enabled'), 'off') = 'on'
     and (
       exists (select 1 from mirror.individuals i
               join mirror.organization_individuals oi on oi.individual_id = i.id and oi.status in ('invited', 'active')
               join mirror.organizations o on o.id = oi.organization_id and o.active
               where i.auth_email = lower(trim(p_email)))
       or exists (select 1 from mirror.organization_members m
                  join mirror.organizations o on o.id = m.organization_id and o.active
                  where m.active and m.auth_email = lower(trim(p_email))));
$$;

create or replace function public.signin_email_on_file(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.condo_email_on_file(p_email) or mirror.email_on_file(p_email);
$$;

-- For /mirror/ pages: who is signed in, as far as the Mirror is concerned. Never another person's data.
create or replace function public.mirror_whoami() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare
  v_email text := lower(auth.email());
  v_aal text := coalesce(auth.jwt() ->> 'aal', '');
  v_person jsonb;
  v_member jsonb;
begin
  if v_email is null then return jsonb_build_object('signed_in', false); end if;
  select jsonb_build_object('id', i.id, 'preferred_name', i.preferred_name) into v_person
    from mirror.individuals i where i.auth_email = v_email;
  select jsonb_agg(jsonb_build_object('organization_id', o.id, 'organization', o.name, 'role', m.role, 'name', m.name) order by o.name) into v_member
    from mirror.organization_members m join mirror.organizations o on o.id = m.organization_id and o.active
    where m.auth_email = v_email and m.active;
  return jsonb_build_object(
    'signed_in', true,
    'email', v_email,
    'aal', v_aal,
    'view_as', public.autopay_view_as_session(),
    'person', v_person,
    'memberships', coalesce(v_member, '[]'::jsonb),
    'needs_authenticator', v_member is not null and v_aal <> 'aal2',
    'signin_enabled', coalesce((select value from public.portal_settings where key = 'mirror_signin_enabled'), 'off') = 'on');
end $$;

revoke all on function mirror.email_on_file(text) from public, anon, authenticated;
grant execute on function mirror.email_on_file(text) to service_role;
revoke all on function public.signin_email_on_file(text) from public, anon, authenticated;
grant execute on function public.signin_email_on_file(text) to service_role;
revoke all on function public.mirror_whoami() from public, anon;
grant execute on function public.mirror_whoami() to authenticated, service_role;
