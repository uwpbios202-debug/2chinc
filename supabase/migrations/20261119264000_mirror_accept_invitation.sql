-- The Human Mirror, Phase 2 fix 1 of 15 (Stephen, 11/13/2026): an invited person never became "active", so coordinators could never
-- see their answers. Now the person accepts (or declines) the invitation on their own My Mirror; accepting makes the link active.
--   mirror_my_invitations()                 the signed-in person's waiting invitations (organization, who added them, since when)
--   mirror_my_invitation_answer(org, yes)   accept -> active (started today) | decline -> ended. Audited. Own Mirror only.
--   mirror_whoami()                         same as before plus 'invitations' (how many are waiting)
-- Nothing changes for people without an email (they are active from the start) or for links already active.

create or replace function public.mirror_my_invitations() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'organization_id', o.id, 'organization', o.name, 'kind', o.kind, 'since', oi.created_at,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id))
    order by oi.created_at)
    from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id and o.active
    where oi.individual_id = v and oi.status = 'invited'), '[]'::jsonb);
end $$;

create or replace function public.mirror_my_invitation_answer(p_org uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if p_accept is null then raise exception 'Choose accept or decline.' using errcode = '22023'; end if;
  update mirror.organization_individuals
     set status = case when p_accept then 'active' else 'ended' end,
         started_on = case when p_accept then current_date else started_on end,
         ended_on = case when p_accept then null else current_date end
   where individual_id = v and organization_id = p_org and status = 'invited'
     and exists (select 1 from mirror.organizations o where o.id = p_org and o.active);
  if not found then raise exception 'There is no waiting invitation from that organization.' using errcode = 'P0002'; end if;
  perform mirror.audit(v, p_org, 'self', case when p_accept then 'invitation_accept' else 'invitation_decline' end, 'general', 'organization_individuals', null);
end $$;

create or replace function public.mirror_whoami() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare
  v_email text := lower(auth.email());
  v_aal text := coalesce(auth.jwt() ->> 'aal', '');
  v_person jsonb;
  v_member jsonb;
  v_invites int := 0;
begin
  if v_email is null then return jsonb_build_object('signed_in', false); end if;
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
    'email', v_email,
    'aal', v_aal,
    'view_as', public.autopay_view_as_session(),
    'person', v_person,
    'memberships', coalesce(v_member, '[]'::jsonb),
    'needs_authenticator', v_member is not null and v_aal <> 'aal2',
    'invitations', v_invites,
    'signin_enabled', coalesce((select value from public.portal_settings where key = 'mirror_signin_enabled'), 'off') = 'on');
end $$;

revoke all on function public.mirror_my_invitations(), public.mirror_my_invitation_answer(uuid, boolean) from public, anon;
grant execute on function public.mirror_my_invitations(), public.mirror_my_invitation_answer(uuid, boolean) to authenticated, service_role;
